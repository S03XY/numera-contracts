/**
 * The shielded pool, exercised against the real deployment.
 *
 * `pool-e2e.mjs` deploys a throwaway pool on anvil and proves against it. This runs the same shape
 * of flow against whatever is in `deployments/<chainid>.json`, on the chain it was deployed to,
 * with the real relayer key and the real collateral. It is the difference between "the code works"
 * and "the thing you are about to demo works".
 *
 * The three flows Numera actually needs, in order:
 *
 *   1. deposit real collateral into the pool                     (public, from a wallet)
 *   2. fund a market execution account out of it                 (private, relayed)
 *   3. return the balance to the pool from that account          (public, from the account)
 *
 * Usage (from contracts/):
 *   node script/pool-live.mjs
 *
 * Reads `PRIVATE_KEY` from contracts/.env (the depositor, which holds test collateral) and
 * `RELAYER_PRIVATE_KEY` from backend/.env (the relayer, which holds the on-chain roles).
 */
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbi,
  parseAbiParameters,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { LeanIMT } from '@zk-kit/lean-imt';
import { poseidon1, poseidon2, poseidon3 } from 'poseidon-lite';
import * as snarkjs from 'snarkjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const ARTIFACTS = join(ROOT, 'frontend', 'public', 'zk');

const F = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const MAX_DEPTH = 32;
const UNIT = 1_000_000n;

const env = (file) =>
  Object.fromEntries(
    readFileSync(join(ROOT, file), 'utf8')
      .split('\n')
      .filter((l) => l.includes('=') && !l.trim().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
  );

const contractsEnv = env('contracts/.env');
const backendEnv = env('backend/.env');
const CHAIN_ID = Number(process.env.CHAIN_ID ?? 10143);
const RPC = process.env.RPC_HTTP_URL ?? backendEnv.RPC_HTTP_URL ?? 'https://testnet-rpc.monad.xyz';
const book = JSON.parse(readFileSync(join(HERE, '..', 'deployments', `${CHAIN_ID}.json`), 'utf8'));

const chain = defineChain({
  id: CHAIN_ID,
  name: `chain-${CHAIN_ID}`,
  nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const hex = (k) => (k.startsWith('0x') ? k : `0x${k}`);
const depositor = privateKeyToAccount(hex(contractsEnv.PRIVATE_KEY));
const relayer = privateKeyToAccount(hex(backendEnv.RELAYER_PRIVATE_KEY));

const publicClient = createPublicClient({ chain, transport: http(RPC) });
const asDepositor = createWalletClient({ account: depositor, chain, transport: http(RPC) });
const asRelayer = createWalletClient({ account: relayer, chain, transport: http(RPC) });

const ENTRYPOINT_ABI = parseAbi([
  'function deposit(uint256 value, uint256 precommitment) returns (uint256)',
  'function relay((address processooor, bytes data) withdrawal, (uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals) proof)',
  'function updateRoot(uint256 root) returns (uint256)',
  'function latestRoot() view returns (uint256)',
  'function shieldNonces(address owner) view returns (uint256)',
  'function depositForWithPermit((address owner, uint256 value, uint256 precommitment, uint256 deadline) req, bytes signature, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) returns (uint256)',
]);
const POOL_ABI = parseAbi([
  'function SCOPE() view returns (uint256)',
  'function currentRoot() view returns (uint256)',
]);
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function mint(address,uint256)',
  'function transfer(address,uint256) returns (bool)',
]);

let passed = 0;
let failed = 0;
const check = (name, ok, detail = '') => {
  if (ok) {
    console.log(`  ✓ ${name}`);
    passed++;
  } else {
    console.error(`  ✗ ${name}${detail ? ` — ${detail}` : ''}`);
    failed++;
  }
};

const noteOf = (value, label, nullifier, secret) =>
  poseidon3([value, label, poseidon2([nullifier, secret])]);

async function tx(wallet, params) {
  const hash = await wallet.writeContract(params);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`reverted: ${hash}`);
  return receipt;
}

const balanceOf = (who) =>
  publicClient.readContract({ address: book.usdc, abi: ERC20_ABI, functionName: 'balanceOf', args: [who] });

const WITHDRAWN = keccak256(new TextEncoder().encode('Withdrawn(address,uint256,uint256,uint256)'));

/**
 * Every leaf the pool has ever inserted, oldest first.
 *
 * Chunked because public RPCs cap the block span of a single `eth_getLogs`, and a pool that has
 * been live for a while spans more than any of them allow. The lookback is bounded rather than
 * from genesis for the same reason; the backend indexer tracks from the deployment block instead
 * of guessing, which is the version that survives the pool getting old.
 */
async function allDeposits(throughBlock = 0n) {
  /*
    A load-balanced public RPC will happily answer `eth_blockNumber` from a node that has not yet
    seen the block our own deposit was mined in. Scanning to that head silently omits the newest
    leaf, and the tree then differs from the pool by exactly one commitment — which surfaces as an
    `UnknownStateRoot` revert long after the cause, or as our own note being absent from the tree
    we just built. `throughBlock` is the receipt's block: never scan short of it.
  */
  let latest = await publicClient.getBlockNumber();
  for (let attempt = 0; latest < throughBlock && attempt < 20; attempt++) {
    await new Promise((r) => setTimeout(r, 500));
    latest = await publicClient.getBlockNumber();
  }
  if (latest < throughBlock) latest = throughBlock;
  // From the deployment, not a lookback. The address book records it precisely, so this costs one
  // query per few thousand blocks instead of forty speculative ones — which is what tipped the
  // public RPC over on the first attempt.
  const from = BigInt(book.deployBlock ?? 0);
  // Monad caps `eth_getLogs` at a 100-block range and answers 413 beyond it. That is fine for a
  // pool deployed minutes ago and hopeless for one that is a week old: scanning from the
  // deployment would be thousands of round trips from a browser. The backend indexer maintains
  // the tree and serves it for exactly this reason; this script scans directly only because it
  // must not depend on the backend being correct in order to test the chain.
  const step = 100n;
  const found = [];
  for (let start = from; start <= latest; start += step) {
    const end = start + step - 1n > latest ? latest : start + step - 1n;
    let logs;
    for (let attempt = 0; ; attempt++) {
      try {
        logs = await publicClient.getLogs({ address: book.privacyPool, fromBlock: start, toBlock: end });
        break;
      } catch (err) {
        // A public RPC refusing one window out of two dozen is ordinary. Failing the whole run for
        // it reports a chain problem that does not exist.
        if (attempt >= 3) throw err;
        await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
      }
    }
    for (const log of logs) {
      const w = log.data.slice(2).match(/.{64}/g)?.map((x) => BigInt(`0x${x}`)) ?? [];
      if (log.topics[0] === DEPOSITED) {
        // Deposited(address indexed depositor, commitment, label, value, precommitmentHash)
        found.push({ commitment: w[0], label: w[1], value: w[2], deposit: true, block: log.blockNumber, index: log.logIndex });
      } else if (log.topics[0] === WITHDRAWN) {
        /*
          Withdrawn(address indexed processooor, value, spentNullifier, newCommitment)

          A withdrawal inserts a leaf too: spending part of a note mints a fresh note for the
          remainder, and that commitment goes into the same tree. Rebuilding from deposits alone
          produces a tree that is correct only until somebody withdraws, and then silently wrong
          for everyone — the root diverges and every subsequent proof is rejected with
          `UnknownStateRoot`. This is the single easiest thing to get wrong about the pool.

          It carries no label of its own: the remainder inherits the lineage of the note it came
          from, and only deposits are ever entered into the association set.
        */
        found.push({ commitment: w[2], label: null, value: w[0], deposit: false, block: log.blockNumber, index: log.logIndex });
      }
    }
  }
  // Block order, then log order within a block: the order the tree was built in.
  return found.sort((a, b) => (a.block === b.block ? a.index - b.index : Number(a.block - b.block)));
}

/** `Deposited(address indexed, uint256, uint256, uint256, uint256)` */
const DEPOSITED = keccak256(new TextEncoder().encode('Deposited(address,uint256,uint256,uint256,uint256)'));
function depositedFrom(receipt) {
  const log = receipt.logs.find((l) => l.topics[0] === DEPOSITED);
  if (!log) throw new Error('no Deposited event');
  const w = log.data.slice(2).match(/.{64}/g).map((x) => BigInt(`0x${x}`));
  return { commitment: w[0], label: w[1], value: w[2] };
}

async function main() {
  console.log(`Shielded pool against the live deployment on chain ${CHAIN_ID}`);
  console.log(`  entrypoint ${book.poolEntrypoint}`);
  console.log(`  pool       ${book.privacyPool}\n`);

  // A fresh address each run, standing in for a market execution account. Fresh because a market
  // account is derived per (user, market) and has no history — reusing one would let a previous
  // run's balance mask a failure here.
  const marketAccount = privateKeyToAccount(
    keccak256(new TextEncoder().encode(`numera-live-${Date.now()}`)),
  );

  const value = 10n * UNIT;
  const withdrawn = 4n * UNIT;
  const nullifier = BigInt(keccak256(new TextEncoder().encode(`n-${Date.now()}`))) % F;
  const secret = BigInt(keccak256(new TextEncoder().encode(`s-${Date.now()}`))) % F;

  // ---------------------------------------------------------------- 1. deposit
  const held = await balanceOf(depositor.address);
  if (held < value) {
    await tx(asDepositor, {
      address: book.usdc, abi: ERC20_ABI, functionName: 'mint', args: [depositor.address, value * 10n],
    });
  }
  await tx(asDepositor, {
    address: book.usdc, abi: ERC20_ABI, functionName: 'approve', args: [book.poolEntrypoint, value],
  });

  const poolBefore = await balanceOf(book.privacyPool);
  const receipt = await tx(asDepositor, {
    address: book.poolEntrypoint,
    abi: ENTRYPOINT_ABI,
    functionName: 'deposit',
    args: [value, poseidon2([nullifier, secret])],
  });
  const { commitment, label } = depositedFrom(receipt);

  check('a real deposit shielded real collateral', (await balanceOf(book.privacyPool)) - poolBefore === value);
  check(
    'the note the chain minted is the one the client would compute',
    noteOf(value, label, nullifier, secret) === commitment,
  );

  // ---------------------------------------------------------------- 2. fund a market account
  /*
    Both trees are rebuilt from EVERY deposit the pool has ever taken, not just this one.

    The first version of this inserted only our own commitment, which passed against a pool with a
    single leaf and then failed the moment a second run added one: the local root diverged and the
    proof was against a state root the pool had never held. A trader is never the only depositor,
    so mirroring the whole tree is not an optimisation — it is the only version that works.

    Order matters. A lean incremental Merkle tree is append-only, so leaves must go in exactly the
    order the chain inserted them, which is block order then log order within a block.
  */
  const deposits = await allDeposits(receipt.blockNumber);
  const state = new LeanIMT((a, b) => poseidon2([a, b]));
  for (const d of deposits) state.insert(d.commitment);
  const chainRoot = await publicClient.readContract({
    address: book.privacyPool, abi: POOL_ABI, functionName: 'currentRoot',
  });
  check(`the state root rebuilt from ${deposits.length} leaf/leaves matches the pool`,
    state.root === chainRoot, `local ${state.root} vs chain ${chainRoot}`);

  // The association set holds labels, and only deposits have one — so its indices are NOT the
  // state tree's indices once a single withdrawal has happened.
  const asp = new LeanIMT((a, b) => poseidon2([a, b]));
  const labels = deposits.filter((d) => d.deposit);
  for (const d of labels) asp.insert(d.label);
  const stateIndex = deposits.findIndex((d) => d.commitment === commitment);
  if (stateIndex === -1) throw new Error('our own deposit is missing from the rebuilt tree');
  const aspIndex = labels.findIndex((d) => d.label === label);
  await tx(asRelayer, {
    address: book.poolEntrypoint, abi: ENTRYPOINT_ABI, functionName: 'updateRoot', args: [asp.root],
  });
  check('the ASP published a root the pool will accept',
    (await publicClient.readContract({
      address: book.poolEntrypoint, abi: ENTRYPOINT_ABI, functionName: 'latestRoot',
    })) === asp.root);

  const scope = await publicClient.readContract({
    address: book.privacyPool, abi: POOL_ABI, functionName: 'SCOPE',
  });
  const withdrawal = {
    processooor: book.poolEntrypoint,
    data: encodeAbiParameters(parseAbiParameters('address'), [marketAccount.address]),
  };
  const context =
    BigInt(
      keccak256(
        encodeAbiParameters(parseAbiParameters('(address processooor, bytes data), uint256'), [
          [withdrawal.processooor, withdrawal.data],
          scope,
        ]),
      ),
    ) % F;

  const sp = state.generateProof(stateIndex);
  const ap = asp.generateProof(aspIndex);
  const pad = (s) => [...s, ...Array(MAX_DEPTH - s.length).fill(0n)];
  const newNullifier = (nullifier + 1n) % F;
  const newSecret = (secret + 1n) % F;

  const started = Date.now();
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    {
      withdrawnValue: withdrawn,
      stateRoot: state.root,
      stateTreeDepth: sp.siblings.length,
      ASPRoot: asp.root,
      ASPTreeDepth: ap.siblings.length,
      context,
      label,
      existingValue: value,
      existingNullifier: nullifier,
      existingSecret: secret,
      newNullifier,
      newSecret,
      stateSiblings: pad(sp.siblings),
      stateIndex: sp.index,
      ASPSiblings: pad(ap.siblings),
      ASPIndex: ap.index,
    },
    join(ARTIFACTS, 'withdraw.wasm'),
    join(ARTIFACTS, 'withdraw.zkey'),
  );
  console.log(`  · proof generated in ${Date.now() - started}ms`);

  const solidityProof = {
    pA: [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])],
    // G2 coordinates are swapped for the Solidity verifier. Wrong here means a proof that verifies
    // off chain and fails on chain, with no useful error.
    pB: [
      [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
      [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
    ],
    pC: [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])],
    pubSignals: publicSignals.map(BigInt),
  };
  check('the nullifier hash matches the client formula', solidityProof.pubSignals[1] === poseidon1([nullifier]));

  await tx(asRelayer, {
    address: book.poolEntrypoint, abi: ENTRYPOINT_ABI, functionName: 'relay',
    args: [withdrawal, solidityProof],
  });

  check('the deployed verifier accepted a real proof', (await balanceOf(marketAccount.address)) === withdrawn);
  check('the remainder stayed shielded', (await balanceOf(book.privacyPool)) - poolBefore === value - withdrawn);
  check('the entrypoint kept nothing', (await balanceOf(book.poolEntrypoint)) === 0n);

  // ---------------------------------------------------------------- 3. return to the pool
  /*
    The market account sends its balance back in, and this is the production path exactly: it holds
    zero MON and never will, because a gas transfer from the trader's wallet would publish the link
    the whole design exists to break.

    So it signs twice and sends nothing. One EIP-2612 permit grants the entrypoint an allowance; one
    EIP-712 `Shield` names the note. The relayer submits both in one transaction and pays for it.
    Neither signature is a prompt the user sees — the market account's key is derived in the browser
    and signing with it is instant.

    The property that makes the relayer harmless here is that `precommitment` is inside the signed
    struct. A relayer that swapped it would produce a signature that recovers to nobody.
  */
  check('the market account still holds no gas', (await publicClient.getBalance({ address: marketAccount.address })) === 0n);

  const returnNullifier = (nullifier + 2n) % F;
  const returnSecret = (secret + 2n) % F;
  const returnPrecommitment = poseidon2([returnNullifier, returnSecret]);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

  const permitSig = await marketAccount.signTypedData({
    domain: { name: 'USD Coin', version: '2', chainId: BigInt(CHAIN_ID), verifyingContract: book.usdc },
    types: {
      Permit: [
        { name: 'owner', type: 'address' },
        { name: 'spender', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    },
    primaryType: 'Permit',
    message: {
      owner: marketAccount.address,
      spender: book.poolEntrypoint,
      value: withdrawn,
      nonce: await publicClient.readContract({
        address: book.usdc, abi: parseAbi(['function nonces(address) view returns (uint256)']),
        functionName: 'nonces', args: [marketAccount.address],
      }),
      deadline,
    },
  });

  const shieldRequest = {
    owner: marketAccount.address,
    value: withdrawn,
    precommitment: returnPrecommitment,
    deadline,
  };
  const shieldSig = await marketAccount.signTypedData({
    domain: {
      name: 'Numera Shielded Pool', version: '1', chainId: BigInt(CHAIN_ID), verifyingContract: book.poolEntrypoint,
    },
    types: {
      Shield: [
        { name: 'owner', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'precommitment', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
      ],
    },
    primaryType: 'Shield',
    message: {
      ...shieldRequest,
      nonce: await publicClient.readContract({
        address: book.poolEntrypoint, abi: ENTRYPOINT_ABI, functionName: 'shieldNonces',
        args: [marketAccount.address],
      }),
    },
  });

  const returnReceipt = await tx(asRelayer, {
    address: book.poolEntrypoint,
    abi: ENTRYPOINT_ABI,
    functionName: 'depositForWithPermit',
    args: [
      shieldRequest,
      shieldSig,
      deadline,
      Number(`0x${permitSig.slice(130, 132)}`),
      `0x${permitSig.slice(2, 66)}`,
      `0x${permitSig.slice(66, 130)}`,
    ],
  });
  const returned = depositedFrom(returnReceipt);

  check('a gasless market account returned its balance by signature', (await balanceOf(marketAccount.address)) === 0n);
  check('the returned note belongs to the trader, not the account',
    noteOf(withdrawn, returned.label, returnNullifier, returnSecret) === returned.commitment);
  check('the pool holds the full deposit again', (await balanceOf(book.privacyPool)) - poolBefore === value);

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('\nFAILED:', err.shortMessage ?? err.message);
  process.exit(1);
});

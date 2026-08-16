/**
 * The shielded pool, proved for real.
 *
 * Everything in `test/pool/NumeraPoolEntrypoint.t.sol` runs against a verifier that returns `true`,
 * because Groth16 proofs cannot be produced inside a Solidity test. That leaves one claim
 * unchecked, and it is the important one: that a proof generated in the browser by our client code
 * is accepted by the verifier we deployed, against a state tree our contracts built.
 *
 * This script closes that gap end to end on a real chain:
 *
 *   1. deploy the collateral, the real Groth16 verifier, the pool and the entrypoint
 *   2. deposit, and read the label the pool assigned out of its own event
 *   3. rebuild the state tree and the association set locally, exactly as the client will
 *   4. publish the ASP root
 *   5. generate a withdrawal proof with snarkjs
 *   6. relay it, and check the money landed on the recipient named inside the proof
 *
 * Then it does the same things wrong on purpose, because a pool that accepts a valid proof is only
 * half of what needs to be true.
 *
 * Usage (from contracts/, with anvil on 8545):
 *   anvil --port 8545 &
 *   node script/pool-e2e.mjs
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
  parseAbiParameters,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { LeanIMT } from '@zk-kit/lean-imt';
import { poseidon1, poseidon2, poseidon3 } from 'poseidon-lite';
import * as snarkjs from 'snarkjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, '..', 'out');
// The artifacts the browser serves, not a copy of them. A reference clone under `resources/` is
// not a place a runtime dependency may live: delete it and the pool stops working. See
// `frontend/public/zk/README.md`.
const ARTIFACTS = join(HERE, '..', '..', 'frontend', 'public', 'zk');
const WASM = join(ARTIFACTS, 'withdraw.wasm');
const ZKEY = join(ARTIFACTS, 'withdraw.zkey');

/** The BN254 scalar field. Every signal, leaf and context is reduced into it. */
const F = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
/** Matches `MAX_TREE_DEPTH` in the circuit build: siblings arrays are padded to this. */
const MAX_DEPTH = 32;
const UNIT = 1_000_000n; // 6-decimal collateral

const RPC = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
// Anvil's first account. A well-known key on a throwaway chain; nothing here touches a real one.
const DEPLOYER = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

const anvil = defineChain({
  id: 31337,
  name: 'anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const account = privateKeyToAccount(DEPLOYER);
const publicClient = createPublicClient({ chain: anvil, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: anvil, transport: http(RPC) });

let passed = 0;
let failed = 0;

function check(name, ok, detail = '') {
  if (ok) {
    console.log(`  ✓ ${name}`);
    passed++;
  } else {
    console.error(`  ✗ ${name}${detail ? ` — ${detail}` : ''}`);
    failed++;
  }
}

/**
 * Deployed library addresses, by library name.
 *
 * `PoseidonT3` and `PoseidonT4` are external libraries, so solc leaves a 20-byte hole in every
 * contract that calls them. Left unlinked the "bytecode" still contains `__$…$__`, and the node
 * rejects it as invalid hex — surfacing as "invalid value: string 0x6101…" from `eth_estimateGas`,
 * which says nothing whatsoever about libraries.
 *
 * The holes are patched by byte offset from the artifact's own `linkReferences` rather than by
 * recomputing the placeholder hash. The placeholder is keccak of a path-and-name string whose
 * exact form is a solc implementation detail — deriving it by hand produced the *other* library's
 * placeholder here, silently, which is the kind of mistake that links a contract to the wrong code.
 */
const libraries = {};

function artifact(file, name) {
  const json = JSON.parse(readFileSync(join(OUT, file, `${name}.json`), 'utf8'));
  let bytecode = json.bytecode.object;
  for (const refs of Object.values(json.bytecode.linkReferences ?? {})) {
    for (const [library, spots] of Object.entries(refs)) {
      const address = libraries[library];
      if (!address) throw new Error(`${name} needs library ${library} deployed first`);
      for (const { start, length } of spots) {
        const from = 2 + start * 2;
        bytecode = bytecode.slice(0, from) + address.slice(2).toLowerCase() + bytecode.slice(from + length * 2);
      }
    }
  }
  return { abi: json.abi, bytecode };
}

async function deployLibrary(file, name) {
  const { address } = await deploy(file, name);
  libraries[name] = address;
  return address;
}

async function deploy(file, name, args = []) {
  const { abi, bytecode } = artifact(file, name);
  const hash = await wallet.deployContract({ abi, bytecode, args });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`${name} deployment reverted`);
  return { address: receipt.contractAddress, abi };
}

async function send(contract, functionName, args) {
  const hash = await wallet.writeContract({
    address: contract.address,
    abi: contract.abi,
    functionName,
    args,
  });
  return publicClient.waitForTransactionReceipt({ hash });
}

/** The same note arithmetic the browser client performs. Poseidon, everywhere. */
const noteOf = (value, label, nullifier, secret) =>
  poseidon3([value, label, poseidon2([nullifier, secret])]);

async function main() {
  console.log(`Shielded pool end-to-end against ${RPC}\n`);

  // ---------------------------------------------------------------- deploy
  // Libraries first: everything below has holes in it until these exist.
  await deployLibrary('PoseidonT3.sol', 'PoseidonT3');
  await deployLibrary('PoseidonT4.sol', 'PoseidonT4');

  const usdc = await deploy('MockERC20.sol', 'MockERC20', ['USD Coin', 'USDC', 6]);
  const verifier = await deploy('WithdrawalVerifier.sol', 'WithdrawalVerifier');
  const ragequit = await deploy('CommitmentVerifier.sol', 'CommitmentVerifier');

  // The pool takes its entrypoint at construction and vice versa, so one address is predicted.
  // Anvil nonces are deterministic, so this is exact rather than hopeful.
  const nonce = await publicClient.getTransactionCount({ address: account.address });
  const { getContractAddress } = await import('viem');
  const entrypointAddress = getContractAddress({ from: account.address, nonce: BigInt(nonce + 1) });

  const pool = await deploy('PrivacyPoolComplex.sol', 'PrivacyPoolComplex', [
    entrypointAddress,
    verifier.address,
    ragequit.address,
    usdc.address,
  ]);
  const entrypoint = await deploy('NumeraPoolEntrypoint.sol', 'NumeraPoolEntrypoint', [
    account.address,
    pool.address,
    usdc.address,
  ]);
  // Case-insensitive: `getContractAddress` returns EIP-55 checksummed, a receipt returns lowercase.
  // The pool would have rejected every deposit had this actually been wrong.
  check(
    'entrypoint deployed at the predicted address',
    entrypoint.address.toLowerCase() === entrypointAddress.toLowerCase(),
    `${entrypoint.address} vs ${entrypointAddress}`,
  );

  const RELAYER_ROLE = await publicClient.readContract({
    address: entrypoint.address, abi: entrypoint.abi, functionName: 'RELAYER_ROLE',
  });
  const POSTMAN_ROLE = await publicClient.readContract({
    address: entrypoint.address, abi: entrypoint.abi, functionName: 'ASP_POSTMAN_ROLE',
  });
  await send(entrypoint, 'grantRole', [RELAYER_ROLE, account.address]);
  await send(entrypoint, 'grantRole', [POSTMAN_ROLE, account.address]);

  await send(usdc, 'mint', [account.address, 1_000n * UNIT]);
  await send(usdc, 'approve', [entrypoint.address, 1_000n * UNIT]);

  // ---------------------------------------------------------------- deposit
  const nullifier = 111222333n;
  const secret = 444555666n;
  const value = 100n * UNIT;
  const precommitment = poseidon2([nullifier, secret]);

  const depositReceipt = await send(entrypoint, 'deposit', [value, precommitment]);
  const deposited = depositReceipt.logs
    .map((log) => {
      try {
        return decodeDeposited(log);
      } catch {
        return null;
      }
    })
    .find(Boolean);
  check('the deposit emitted a note', Boolean(deposited));

  const { label, commitment } = deposited;
  check(
    'the commitment the pool computed matches the one the client would',
    noteOf(value, label, nullifier, secret) === commitment,
    `chain ${commitment} vs client ${noteOf(value, label, nullifier, secret)}`,
  );

  // ---------------------------------------------------------------- local trees
  // The client mirrors both trees from events. Any drift here and the proof is against a root the
  // pool has never seen, which is precisely the failure mode `UnknownStateRoot` exists to catch.
  const state = new LeanIMT((a, b) => poseidon2([a, b]));
  state.insert(commitment);
  const onChainRoot = await publicClient.readContract({
    address: pool.address, abi: pool.abi, functionName: 'currentRoot',
  });
  check('the locally rebuilt state root matches the pool', state.root === onChainRoot,
    `local ${state.root} vs chain ${onChainRoot}`);

  // Our association set approves every deposit, so the tree is simply every label we have seen.
  const asp = new LeanIMT((a, b) => poseidon2([a, b]));
  asp.insert(label);
  await send(entrypoint, 'updateRoot', [asp.root]);

  // ---------------------------------------------------------------- prove
  const recipient = '0x000000000000000000000000000000000000dEaD'; // stands in for a market account
  const withdrawn = 40n * UNIT;
  const newNullifier = 777888999n;
  const newSecret = 121314151n;

  const scope = await publicClient.readContract({
    address: pool.address, abi: pool.abi, functionName: 'SCOPE',
  });
  const withdrawal = { processooor: entrypoint.address, data: encodeAbiParameters(parseAbiParameters('address'), [recipient]) };
  const context =
    BigInt(
      keccak256(
        encodeAbiParameters(parseAbiParameters('(address processooor, bytes data), uint256'), [
          [withdrawal.processooor, withdrawal.data],
          scope,
        ]),
      ),
    ) % F;

  const sProof = state.generateProof(0);
  const aProof = asp.generateProof(0);
  const pad = (s) => [...s, ...Array(MAX_DEPTH - s.length).fill(0n)];

  const started = Date.now();
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    {
      withdrawnValue: withdrawn,
      stateRoot: state.root,
      stateTreeDepth: sProof.siblings.length,
      ASPRoot: asp.root,
      ASPTreeDepth: aProof.siblings.length,
      context,
      label,
      existingValue: value,
      existingNullifier: nullifier,
      existingSecret: secret,
      newNullifier,
      newSecret,
      stateSiblings: pad(sProof.siblings),
      stateIndex: sProof.index,
      ASPSiblings: pad(aProof.siblings),
      ASPIndex: aProof.index,
    },
    WASM,
    ZKEY,
  );
  console.log(`  · proof generated in ${Date.now() - started}ms`);

  const solidityProof = {
    pA: [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])],
    // Groth16 G2 points are swapped when passed to the Solidity verifier. Getting this wrong
    // produces a proof that verifies off chain and fails on chain, which is a miserable afternoon.
    pB: [
      [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
      [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
    ],
    pC: [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])],
    pubSignals: publicSignals.map(BigInt),
  };

  check(
    'the nullifier hash in the proof is the one the client computes',
    solidityProof.pubSignals[1] === poseidon1([nullifier]),
  );

  // ---------------------------------------------------------------- relay
  const before = await balanceOf(recipient);
  await send(entrypoint, 'relay', [withdrawal, solidityProof]);
  const after = await balanceOf(recipient);

  check('the real verifier accepted a real proof', after - before === withdrawn,
    `recipient gained ${after - before}, expected ${withdrawn}`);
  check('the remainder stayed shielded', (await balanceOf(pool.address)) === value - withdrawn);
  check('the entrypoint kept nothing', (await balanceOf(entrypoint.address)) === 0n);

  // ---------------------------------------------------------------- negative
  await expectRevert('the same proof cannot be replayed',
    () => send(entrypoint, 'relay', [withdrawal, solidityProof]));

  const redirected = {
    processooor: entrypoint.address,
    data: encodeAbiParameters(parseAbiParameters('address'), [account.address]),
  };
  await expectRevert('a relayer cannot redirect a payout to itself',
    () => send(entrypoint, 'relay', [redirected, solidityProof]));

  const tamperedValue = { ...solidityProof, pubSignals: [...solidityProof.pubSignals] };
  tamperedValue.pubSignals[2] = 90n * UNIT; // ask for more than the proof attests to
  await expectRevert('a tampered withdrawal amount is rejected',
    () => send(entrypoint, 'relay', [withdrawal, tamperedValue]));

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);

  // ---------------------------------------------------------------- helpers
  async function balanceOf(who) {
    return publicClient.readContract({
      address: usdc.address, abi: usdc.abi, functionName: 'balanceOf', args: [who],
    });
  }

  async function expectRevert(name, fn) {
    try {
      await fn();
      check(name, false, 'the call succeeded when it should have reverted');
    } catch {
      check(name, true);
    }
  }

  function decodeDeposited(log) {
    // `Deposited(address indexed depositor, uint256 commitment, uint256 label, uint256 value,
    //  uint256 precommitmentHash)` — four unindexed words after the topic.
    const DEPOSITED = keccak256(
      new TextEncoder().encode('Deposited(address,uint256,uint256,uint256,uint256)'),
    );
    if (log.topics[0] !== DEPOSITED) throw new Error('not the deposit');
    const words = log.data.slice(2).match(/.{64}/g).map((w) => BigInt(`0x${w}`));
    return { commitment: words[0], label: words[1], value: words[2] };
  }
}

main().catch((err) => {
  console.error('\nFAILED:', err.message);
  process.exit(1);
});

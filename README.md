# Numera contracts

A prediction market where prices are public and traders are not. Every market runs on a damped
LS-LMSR book; every bet is placed from a per-market account funded out of a shielded pool, so the
position is visible and its owner is not.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together, and
[DEPLOYMENT_READINESS.md](DEPLOYMENT_READINESS.md) for what has to be true before a real deployment.

## Deployed — Monad testnet (chain 10143)

Deployed at block **54188065**. Admin and deployer:
[`0xb27c7FEC99Bc20f25E78594510E03359ED7Be8A8`](https://testnet.monadexplorer.com/address/0xb27c7FEC99Bc20f25E78594510E03359ED7Be8A8).

**[`deployments/10143.json`](deployments/10143.json) is the source of truth.** The backend, the
frontend and every script read it directly; this table is a convenience copy for humans and is the
only place these addresses are written by hand. If the two disagree, the JSON is right and this is
stale — regenerate it rather than editing one line.

### The market

| Contract | Address | What it does |
| --- | --- | --- |
| `LsLmsrMarket` | [0x92fb48272EB93e44AA190f9199AF4F4e8E002D1C](https://testnet.monadexplorer.com/address/0x92fb48272EB93e44AA190f9199AF4F4e8E002D1C) | The engine. Every market, every trade, every payout. |
| `MarketFactory` | [0xf7541bdF95007d03B2CeABd55A230B82db6cFf34](https://testnet.monadexplorer.com/address/0xf7541bdF95007d03B2CeABd55A230B82db6cFf34) | Creates markets and holds the engine registry. |
| `TestUSDC` | [0xB950d6ab271c752f3b27dbc10441f4e1ca4d71af](https://testnet.monadexplorer.com/address/0xB950d6ab271c752f3b27dbc10441f4e1ca4d71af) | Collateral. EIP-2612 permit, EIP-3009, and a rate-limited faucet. |
| `TradingBlocklist` | [0x2120e5271A945c9319e8e06B00AaecA14f181d9D](https://testnet.monadexplorer.com/address/0x2120e5271A945c9319e8e06B00AaecA14f181d9D) | Shared ban list, read by every engine. |

### Settlement

| Contract | Address | What it does |
| --- | --- | --- |
| `OptimisticResolver` | [0x6F0F443097d56AD118960067b4E9F8486699d5d9](https://testnet.monadexplorer.com/address/0x6F0F443097d56AD118960067b4E9F8486699d5d9) | Bonded proposals and the dispute window. |
| `TrustedResolver` | [0x15a6BfCd584b5A6A0a1d26381e2b90989Cf4Da94](https://testnet.monadexplorer.com/address/0x15a6BfCd584b5A6A0a1d26381e2b90989Cf4Da94) | The only contract the engine accepts an outcome from. |
| `ResolverMultisig` | [0xa26aae6a18B1f912b7D9604BEf81a886810537E9](https://testnet.monadexplorer.com/address/0xa26aae6a18B1f912b7D9604BEf81a886810537E9) | The arbitration quorum — the only thing that can overturn a proposal. |

On this deployment the dispute window is **10 minutes**, so settlement can be exercised in a
sitting. Raise `DISPUTE_WINDOW` before any deployment where the outcome matters: the window is the
only opportunity anyone has to challenge a false result.

### The shielded pool

| Contract | Address | What it does |
| --- | --- | --- |
| `NumeraPoolEntrypoint` | [0xde3131ea3680c4e470c12c8F5B1262CA6a657357](https://testnet.monadexplorer.com/address/0xde3131ea3680c4e470c12c8F5B1262CA6a657357) | The only door into and out of the pool. |
| `PrivacyPool` | [0xc52F2F283329c2fD7B5EbE60760C4051A064C97F](https://testnet.monadexplorer.com/address/0xc52F2F283329c2fD7B5EbE60760C4051A064C97F) | Holds the shielded collateral and the commitment tree. |
| `WithdrawalVerifier` | [0x9cFf02E81b68359F8Fe0f8163575d6065b323285](https://testnet.monadexplorer.com/address/0x9cFf02E81b68359F8Fe0f8163575d6065b323285) | Groth16 verifier for withdrawal proofs. |
| `CommitmentVerifier` | [0x18abfD15A0049F79d1c3C93faB5CB12233fc92Db](https://testnet.monadexplorer.com/address/0x18abfD15A0049F79d1c3C93faB5CB12233fc92Db) | Groth16 verifier for the ragequit path. |

### Sponsored execution

| Contract | Address | What it does |
| --- | --- | --- |
| `NumeraForwarder` | [0x4051483F47F3E9290db72de3a78b26E02b71Da1D](https://testnet.monadexplorer.com/address/0x4051483F47F3E9290db72de3a78b26E02b71Da1D) | Relays trades. One frozen destination, five permitted selectors. |
| `ResolutionForwarder` | [0xd1191845002f4F3a732f9AD3d488ecB9895f20Fd](https://testnet.monadexplorer.com/address/0xd1191845002f4F3a732f9AD3d488ecB9895f20Fd) | Relays proposals and disputes, so proposing needs no gas. |

A market account holds **zero native gas for its entire life**, and that is a privacy property
rather than a convenience: a gas transfer from a trader's own wallet would publish the link between
them and every position that account will ever hold. The account signs; the relayer sends.

## Source verification

Monad testnet has **two independent explorers, with two separate verification systems**, and
verifying on one does nothing for the other. This is the detail that wastes an afternoon:

| Explorer | Verification route | Needs a key |
| --- | --- | --- |
| [testnet.monadscan.com](https://testnet.monadscan.com) | Etherscan V2 API, `chainid=10143` | yes — an Etherscan key |
| [testnet.monadexplorer.com](https://testnet.monadexplorer.com) (MonadVision) | its own "Verify Code" flow | — |
| [sourcify.dev](https://sourcify.dev) | Sourcify, chain 10143 | no |

Every contract above is verified on **Sourcify**, which is the explorer-independent record: it
recompiles the source and compares it against the deployed bytecode, and anyone can check the
result without trusting us or any one explorer. Neither Monad explorer reads it, so a contract can
be fully verified on Sourcify and still show "Contract not verified" on the explorer page — which
is a statement about that explorer's index, not about the source.

All thirteen, on whichever explorer you name — addresses come from the address book, so it cannot
drift from what was deployed:

```shell
$ ./script/verify.sh sourcify                       # no key needed
$ ETHERSCAN_API_KEY=… ./script/verify.sh monadscan  # one key covers every Etherscan V2 chain
```

To verify one contract on Sourcify:

```shell
$ forge verify-contract <address> src/pool/NumeraPoolEntrypoint.sol:NumeraPoolEntrypoint \
    --chain-id 10143 --verifier sourcify \
    --verifier-url https://sourcify.dev/server --watch
```

No `--constructor-args` is needed. Sourcify recompiles and compares the *deployed* bytecode, so it
derives the arguments rather than being told them — which is one fewer thing to get wrong than the
Etherscan flow, where a mis-encoded tuple fails with an error that names neither the argument nor
the type.

To check what is verified rather than trusting the last run:

```shell
$ curl -s https://sourcify.dev/server/v2/contract/10143/<address> | jq .match
```

Two settings in `foundry.toml` bear on this and should not be changed casually.
`bytecode_hash = "none"` and `cbor_metadata = false` strip the metadata trailer from the deployed
code, which keeps builds reproducible across machines. Verification still reaches a full `match`
because the comparison is over the bytecode itself, but anything that relies on reading an IPFS
metadata hash out of the deployed code will find nothing there.

## Verifying a deployment yourself

The address book records what was deployed, not that it was wired correctly. These read the chain:

```shell
# the forwarder can only ever call the engine
cast call <NumeraForwarder> "market()(address)" --rpc-url monad_testnet

# the pool answers to its entrypoint, and only its entrypoint
cast call <PrivacyPool> "ENTRYPOINT()(address)" --rpc-url monad_testnet

# the dispute window a proposal will actually get
cast call <OptimisticResolver> "disputeWindow()(uint64)" --rpc-url monad_testnet
```

End to end, against the live deployment rather than a fork:

```shell
node script/pool-live.mjs        # deposit, prove, relay, return — all three flows, real proofs
```

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

Writes `deployments/<chainid>.json`, which everything else reads.

```shell
$ forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast --slow
```

Reads `PRIVATE_KEY`, `ADMIN`, `USDC_ADDRESS`, `RELAYER_ADDRESS` and the parameter overrides from
`.env`. Leaving `USDC_ADDRESS` unset deploys a fresh `TestUSDC`; setting it reuses the token already
in circulation, which is usually what you want so existing test balances survive.

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

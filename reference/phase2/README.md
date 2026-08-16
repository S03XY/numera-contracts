# Superseded — this whole directory is history

Everything here was built on 2026-08-09, taken out of the build the same day, and **brought back on
2026-08-10 in a revised form**. Nothing in this folder is compiled: Foundry only walks `src/` and
`test/`. It is kept as a record of what the first attempt looked like, and nothing more.

Do not edit these files, and do not copy from them. Every one has a live successor:

| here | live version | what changed |
|---|---|---|
| `PrivateOptimisticResolver.sol` | `src/resolvers/OptimisticResolver.sol` | dynamic pot-scaled bond with a clamp, a proposal fee, a bond-free path for operator wallets, arbitration reachable from an *undisputed* proposal, slashing to the pool instead of to the winner, and a ban on the losing account |
| `ResolutionForwarder.sol` | `src/relay/ResolutionForwarder.sol` | `dispute` now carries a counter-outcome |
| `ResolverMultisig.sol` | `src/resolvers/ResolverMultisig.sol` | unchanged; it now holds `ARBITRATOR_ROLE` rather than `RESOLVER_ROLE` |
| `MockOptimisticMarket.sol` | `src/mocks/MockOptimisticMarket.sol` | adds `feesOf`, `isSettled`, and a switch to make the optional views revert |
| `PrivateOptimisticResolver.t.sol` | `test/unit/OptimisticResolver.t.sol` | 69 tests against the revised design |
| `RelayedResolution.t.sol` | `test/RelayedResolution.t.sol` | 14 tests; same privacy property, new signatures |
| `ResolverMultisig.t.sol` | `test/unit/ResolverMultisig.t.sol` | unchanged, 39 tests |
| `DeployPrivateResolution.s.sol` | `script/Deploy.s.sol` | the whole stack deploys in one script now |
| `AdoptResolverMultisig.s.sol` | — | no successor. It migrated a *live* resolver's roles onto a quorum, which the fresh deployment does not need. Kept in case a future migration wants the shape. |

## What the first attempt got wrong

Two things, both economic rather than mechanical.

1. **A flat bond.** It was the same size on a market holding 50 USDC as on one holding 50,000, so it
   was simultaneously too large to bother with on a small market and far too small to deter a lie on
   a large one. The bond now scales with the pot and is clamped at both ends.
2. **No route for the operator to settle quickly.** Every settlement had to wait out the dispute
   window even when nobody disputed anything, and the operator's only ways in were "nobody proposed"
   or "somebody already disputed". Operator wallets now propose without a bond, and the thing that
   keeps that honest is that their proposal is challengeable on identical terms.

The privacy property was right the first time and is unchanged: a market account proposes and
disputes while holding zero native gas, so the proposer never leaves the anonymity set its trades
are in. `test/RelayedResolution.t.sol` still proves it.

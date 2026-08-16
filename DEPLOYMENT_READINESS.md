# Deployment Readiness

Status of the private prediction-market contracts as of the hardening pass.

## Verdict

- ✅ **Ready for real-world *testnet* user testing** (Monad testnet, test funds).
- ⛔ **Not yet for mainnet real money** — requires a professional audit and a validated live-Unlink
  integration first (see "Before mainnet").

The code itself is in strong shape; the mainnet blockers are process/integration, not logic defects.

## Test suite — 205 tests, all passing

| Kind | What it proves |
|---|---|
| Unit (positive/negative) | Every function's happy path + every revert/guard, across all 7 contracts |
| Fuzz | Payout math never over-pays; LMSR `C(q) ≥ qᵢ`; fee conservation |
| **Stateful invariants** (8,192 random calls each) | **Money conserved** (`vault balance == pot + fees`), **solvent for every outcome**, **prices sum to 1** — held over thousands of random buy/sell sequences with 0 reverts |
| Lifecycle stress | Full create→trade→resolve→redeem→LP-settle→fee-withdraw: LMSR drains to **exactly 0**, parimutuel leaves only bounded sub-unit dust |
| Hot-market stress | 3,000 interleaved buys/sells (World Cup final): solvency + price invariants held; gas/fees/throughput measured |
| Unlink integration | Position keyed to ephemeral ExecutionAccount, never `tx.origin`; atomic batch; `returnToPool`; cross-account claim rejected |

**Coverage:** 91.6% lines · 80% branches · 97% functions. Libraries and resolvers at ~100%; the
uncovered branches are defensive guards (e.g. deflationary-collateral checks) exercised by the
fuzz/invariant suites rather than dedicated unit cases.

## Hardening applied this pass

- **Input bounds** — LMSR `b` capped at `MAX_LIQUIDITY_PARAM` (1e30) and per-trade `sharesOut` at
  `MAX_SHARES_PER_TRADE`, eliminating any fixed-point overflow / DoS from pathological inputs.
- **Deflationary-collateral guard** verified — buys revert if the token delivers less than required.
- **Stateful invariant suites** added for both engines (the biggest confidence lift for a money contract).
- **Full-lifecycle conservation** proven through settlement, not just trading.
- **Branch coverage** raised 65% → 80% by closing view-revert and settlement-state gaps.

## Verified engineering properties

- No `tx.origin` in executable code (privacy-critical) — grep-verified.
- CEI + `nonReentrant` on every state-changing external call; `SafeERC20` throughout.
- Balance-delta accounting (robust vs fee-on-transfer tokens).
- Immutable market parameters after creation (no rug on committed bettors).
- All contracts under the 24 KB size limit.
- Clean compile on Solidity 0.8.28 / EVM Cancun (Monad-compatible).

## Before mainnet (real money) — required, not optional

1. **Professional security audit** — tests check what we anticipated; an audit finds what we didn't.
2. **Live Unlink integration on Monad testnet** — the privacy guarantee depends on real Unlink
   ExecutionAccount behavior (fresh-per-bet, reuse-to-claim), currently proven only against a mock.
3. **Non-custodial frontend/SDK** — the spending key must stay client-side, or privacy is lost.
4. **Ops hardening** — `DEFAULT_ADMIN_ROLE` on the resolver, engine and factory moved off the
   deployer key to a multisig (+ timelock); monitoring; a pause/incident runbook.
   *Today one key settles every market. That is a deliberate phase-1 choice, not an oversight, but
   it is the first thing to change when real money is involved.*
5. **Economic review** — `b` sizing and fees for real books.

## Known, accepted limitations

- Privacy strength scales with Unlink's **anonymity set** and correct SDK usage (fresh accounts,
  denominations, timing) — an app/ops concern, not a contract one.
- ZK privacy (Groth16) is **not post-quantum**; "hidden forever" is bounded by that assumption.
- Resolution is **trusted, by design**: wallets holding `RESOLVER_ROLE` settle every market, and the
  operator decides who holds it. Each holder settles alone.
  That trust is bounded and public — the quorum cannot touch trader funds, positions or the engine,
  only outcomes, and every settlement is an on-chain transaction anyone can check. It is not
  minimized further because the alternative (permissionless bonded proposals) would have traders
  correlating their own wallets with their positions, which costs more privacy than it buys trust.
- Contracts are **immutable** — a bug means redeploy + migrate, not upgrade.

## Recommended path

Testnet now → validate live Unlink → audit → limited mainnet beta (capped sizes, bug bounty) → full launch.

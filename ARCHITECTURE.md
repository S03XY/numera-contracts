# Private Prediction Market — Architecture

A generic, category-agnostic prediction marketplace for **Monad**, where **market data and
prices are public but the trader placing each bet is hidden**. Privacy is delegated to
[**Unlink**](https://docs.unlink.xyz) (a ZK shielded pool); the contracts here are engineered to be
*natively compatible* with Unlink's execution model without ever leaking trader identity.

Supports **binary (Yes/No)** and **multi-outcome** markets, two pricing engines, USDC collateral,
and fully configurable parameters per market.

---

## 1. The core insight: Unlink is the privacy layer

Unlink is a smart contract (shielded pool) using encrypted UTXO notes + Groth16 proofs. To interact
with an external contract, a user calls Unlink `execute()`:

1. Collateral is withdrawn from the shielded pool into a **fresh ERC-4337 `ExecutionAccount`**.
2. That account calls our market — so from the market's perspective **`msg.sender` is an ephemeral,
   unlinkable account**, and `tx.origin` is Unlink's bundler.
3. It runs as a **sponsored UserOperation** (paymaster pays gas); up to 16 calls batch atomically.
4. Proceeds paid back to `msg.sender` can be swept into the pool via **`returnToPool`** — same UserOp.

A second on-chain ZK layer would be redundant (Unlink already unlinks identity) and would fight the
"fast/efficient" goal. Instead, the market is designed around a strict set of **Unlink-native
constraints**, each enforced and tested:

| Constraint | Reason |
|---|---|
| ERC-20 (USDC) collateral only, `value = 0` | `execute()` uses ERC-20 flows, no native token |
| Ownership keyed to `msg.sender`, **never `tx.origin`** | caller is the ExecutionAccount; `tx.origin` is the shared bundler |
| No native-gas assumptions | gas is paymaster-sponsored |
| Atomic `approve + bet` in one batch works | Unlink sends one UserOp |
| Proceeds paid to `msg.sender` | so they sweep back to the shielded pool |
| Internal ledgers, **no transferable position tokens** | transfers create linkage; internal balances are more private and cheaper |

**Privacy result:** bet from a *fresh* ExecutionAccount per position ⇒ bets are uncorrelated;
claim by *reusing that slot* ⇒ identity still hidden. The real trader never appears on-chain.
The `test/integration/UnlinkFlow.t.sol` suite proves each property (including that a different account
— even with the same `tx.origin` — cannot claim another's winnings).

---

## 2. Component map

```
                          ┌────────────────────┐
                          │   MarketFactory     │  registry + category catalog + market index
                          │  (discovery only)   │  — no collateral, no identity → no privacy surface
                          └─────────┬───────────┘
              registers │           │ registers
                        ▼           ▼
        ┌───────────────────┐   ┌───────────────────┐
        │ ParimutuelMarket  │   │    LMSRMarket      │   pricing engines (hold USDC vaults)
        │  pooled payouts   │   │ live price-shift   │
        └─────────┬─────────┘   └─────────┬──────────┘
                  │  resolver hook (IResolvableMarket)
                  ▼             ▼
              ┌───────────────────────┐
              │    TrustedResolver    │   the role gate each market is bound to, forever
              └───────────┬───────────┘
                          │ sole holder of RESOLVER_ROLE
              ┌───────────┴───────────┐
              │  OptimisticResolver   │──► TradingBlocklist (bans the losing account)
              │  bonds · window ·     │
              │  rewards · slashing   │◄── ResolutionForwarder (private propose/dispute)
              └───────────┬───────────┘
                          │ ARBITRATOR_ROLE
              ┌───────────┴───────────┐
              │   ResolverMultisig    │   m-of-n; rules on disputes, reaches nothing else
              └───────────────────────┘

  Libraries:  ParimutuelMath · LMSRMath (PRBMath exp/ln) · Constants · MarketTypes · Errors · Roles
  Users reach the engines exclusively through Unlink `execute()` (ExecutionAccount = msg.sender).
```

Engines are **monolithic hubs** (many markets in one contract): one stable Unlink target address,
cheap market creation (a struct, not a deployment), and a shared per-token vault.

---

## 3. Pricing engines

### 3a. `ParimutuelMarket` — pooled
Each outcome has a pool; the total pot (minus a configurable protocol fee) is split pro-rata among
winners. `payout = stake · netPot / winningPool`. Simple, no liquidity provider, no
impermanent-loss — ideal for sports. Prices are the public pool ratios (`priceWad`). If resolved to
a zero-stake outcome, it auto-voids to refunds (no stuck funds).

### 3b. `LMSRMarket` — Logarithmic Market Scoring Rule (live prices)
The engine you asked for: **every buy shifts the public price.**

- Cost `C(q) = b·ln(Σ exp(qᵢ/b))`; price `pᵢ = exp(qᵢ/b) / Σ exp(qⱼ/b)` (prices always sum to 1).
- Buying outcome *i* raises `qᵢ` ⇒ raises `pᵢ`, visible immediately via `prices()` / `priceWad()`.
- **Bounded loss:** the maker's max subsidy is exactly `C(0) = b·ln(N)`, seeded at creation.
  Elegant invariant — **collateral held always equals `C(q)`** — so the market is provably solvent
  (`C(q) ≥ qᵢ` for every outcome ⇒ winners always fully covered).
- `exp`/`ln` via the audited **PRBMath** `SD59x18`. Numerically stable: every exponent is
  `(qᵢ − qmax)/b ≤ 0`, so `exp ∈ (0,1]` never overflows and `ln` only sees a sum ≥ 1.
- Rounding is asymmetric (buys round up, sells round down) so the pool never becomes insolvent.
- Slippage guards (`maxCost` on buy, `minRefund` on sell). Invalidation refunds each trader's net
  cost basis; the LP takes the residual (≥ 0 by bounded loss), computed exactly via an O(1)
  `sumPositiveNet` aggregate so settlement is order-independent.

---

## 4. Resolution & lifecycle

`Trading → Resolved` (winning outcome set; winners claim) **or** `Trading → Invalid` (everyone
refunds). Betting is open while `block.timestamp < closeTime`; resolution requires close to have
passed. Each market stores a per-market `resolver` address — the engine only checks
`msg.sender == resolver`, so the resolution source is **fully swappable per market**. One is
shipped, deliberately:

**`TrustedResolver`** — the thin role gate every market is bound to. `resolveMarket` and
`invalidateMarket` are both `onlyRole(RESOLVER_ROLE)`, and after deployment **exactly one address
holds that role: `OptimisticResolver`.** The operator's own `RESOLVER_ROLE` is revoked by the deploy
script, which is the line that makes everything below true rather than merely intended — with it in
place the operator would have a direct route to the engine that skips the challenge window entirely.

The indirection is not ceremony. A market's `resolver` is fixed at creation, so a market bound
straight to an EOA becomes permanently unresolvable if that key is lost, with trader funds stuck
behind it. One thin contract makes the entire settlement layer above it replaceable without
touching a single market.

**`OptimisticResolver`** — bonded, private, permissionless proposals with a quorum behind them.

```
closeTime ── trading stops ──┐   no deadline to propose: a market waits as long as it needs to
     ┌───────────────────────┴───────────────────────┐
  PROPOSE (public)                            PROPOSE (operator / trusted wallet)
  bond + fee, relayed, private                no bond, no fee
     └──────────────► dispute window ◄────────────────┘   configurable; BOTH are challengeable
                            │
        ┌───────────────────┴───────────────────┐
   nobody disputes                        DISPUTE (bond, relayed)
        │                                       │
   FINALIZE (anyone)                      ARBITRATE (ResolverMultisig)
   bonded proposer takes                 wrong side forfeits the bond into the reward
   bond back + reward                    pool AND is written to TradingBlocklist;
                                         right side takes bond back + reward
```

- **The bond is flat** (`bond`), the same on every market. It replaced a version that scaled with
  the pot, and the scaling was dropped because it never tracked what it claimed to: the thing a bond
  must outweigh is the liar's *position*, which is shielded, and the pot is only a very loose upper
  bound on it. The clamp that sizing needed already conceded the point. What the bond actually does
  is deter spam and put skin in the game, neither of which grows with the book — and what stops an
  unchallenged lie is `arbitrate` reaching a `Proposed` market, not the size of the stake.
- **The reward is a share of that market's own fee revenue** (`feesOf(marketId)` on the engine),
  capped. Paid from a pool the operator funds and forfeited bonds top up.
- **The operator proposes without a bond, and gains nothing else.** A bond-free proposal opens the
  identical window and is overturned by the identical quorum. Speed, not finality.
- **Being wrong costs twice**: the bond is forfeited into the pool, and the market account is barred
  from trading via `TradingBlocklist`. The ban reaches trading only — `redeem` stays open, because
  the penalty for lying is the forfeit and the loss of access, not confiscation of money won before
  the lie.
- **Liveness is permissionless.** `resetStuckDispute` and `abandonProposal` return stakes after
  `arbitrationTimeout`, so no silence from the quorum can lock a bond forever.
- **The backend holds no key on any of it.** There is no "resolve" endpoint, so compromising the API
  cannot settle a market.

**`ResolverMultisig`** — an m-of-n quorum holding `ARBITRATOR_ROLE`, with an adopted target set
containing only the optimistic resolver. Membership is the operator's call; what gets ruled on is
the signers'. The honest consequence, stated rather than hidden: an operator who can reshape the set
can reduce it to one wallet. This defends against a signer going rogue, not against the operator.

**How proposing stays private.** Whoever proposes an outcome is, overwhelmingly, someone holding it,
so a proposal signed by a login wallet would correlate that wallet with a shielded position — the
one leak the rest of the design cannot undo. `ResolutionForwarder` (ERC-2771, one frozen
destination, two selectors) relays `propose` and `dispute` from the same market account that placed
the bets, holding zero native gas. `RelayedResolution.t.sol` proves it with a zero-balance account.
`finalize` is deliberately **not** relayable: it pays the recorded proposer whoever calls it, so the
caller is not the beneficiary and has nothing to hide.

- An outcome of `INVALID_OUTCOME` routes to `invalidate` (full refunds).

---

## 5. Configurability (per market, immutable after creation)

`collateral` (USDC), `resolver`, `closeTime`, `outcomeCount` (2–256 parimutuel / 2–64 LMSR),
`feeBps` (≤ 10%), `category` (any tag), `metadataHash`, plus `minBet` (parimutuel) or `b` liquidity
(LMSR). Parameters are frozen at creation so operators cannot alter fees/close-time/outcomes after
bettors commit funds. Protocol-level: `AccessControl` roles (admin, market-creator, resolver, pauser,
fee-manager, curator, arbitrator, blocklist), emergency `pause` (betting only — exits always allowed), and fee withdrawal.

---

## 6. Safety properties (all tested — 522 tests, incl. stateful invariants)

- **No `tx.origin`** anywhere in executable code (grep-verified) — the whole privacy model depends on this.
- **CEI + `nonReentrant`** on every state-changing external call; **SafeERC20** throughout.
- **Balance-delta accounting** on deposits (robust even vs fee-on-transfer tokens).
- **Full-precision math** (`Math.mulDiv`, PRBMath) — fuzz-proven that payouts never exceed the pot and
  that `C(q) ≥ qᵢ`.
- **O(1) claim/refund** (no unbounded loops over bettors).
- Positive **and** negative coverage for every path (access control, timing, slippage, double-claim,
  invalid outcome, etc.).

---

## 7. Layout

```
src/
  MarketFactory.sol            registry + category catalog + market index
  markets/
    ParimutuelMarket.sol       pooled engine
    LMSRMarket.sol             LMSR live-pricing engine
  resolvers/
    TrustedResolver.sol          the thin role gate every market is bound to
    OptimisticResolver.sol       bonded proposals, disputes, rewards, slashing, bans
    ResolverMultisig.sol         m-of-n quorum holding ARBITRATOR_ROLE
  access/
    Roles.sol                    canonical role identifiers
    TradingBlocklist.sol         accounts barred from trading, shared by every engine
  relay/
    NumeraForwarder.sol          gasless trading from a market account
    ResolutionForwarder.sol      gasless proposing and disputing from the same account
  access/Roles.sol                canonical role identifiers
reference/phase2/                 quorum + bonded private resolution, out of the build
  libraries/                   ParimutuelMath, LMSRMath, Constants, MarketTypes, Errors
  access/Roles.sol
  interfaces/                  IResolvableMarket, IMarketEngine
  mocks/                       MockERC20, MockFeeOnTransferERC20, MockExecutionAccount, MockResolvableMarket
test/
  unit/                        per-module positive + negative + fuzz
  integration/UnlinkFlow.t.sol end-to-end Unlink execute() privacy proof
script/Deploy.s.sol            Monad deployment + registry wiring
```

## 8. Deploy (Monad)

```bash
export PRIVATE_KEY=0x...
export USDC_ADDRESS=0x...          # real USDC on Monad; omit on a bare testnet to auto-deploy a mock
forge script script/Deploy.s.sol:Deploy --rpc-url monad_testnet --broadcast
```

Then, as admin: create markets on an engine (so the LMSR liquidity-provider identity is the real
creator), bind each market's `resolver` to `TrustedResolver`, and `factory.recordMarket(...)` to index
them. Traders fund Unlink and interact through `execute()` — staying private while prices stay public.

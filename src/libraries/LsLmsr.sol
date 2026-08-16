// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SD59x18, sd, ZERO, UNIT} from "@prb/math/src/SD59x18.sol";

/// @title LsLmsr
/// @notice Damped Liquidity-Sensitive LMSR cost function for categorical prediction markets.
///
/// @dev ## Mechanism
///
/// Over `n` mutually exclusive, exhaustive outcomes with share vector `q`:
///
///     s     = Σ qᵢ
///     b(s)  = α · (s + √(s · s*))
///     C(q)  = b · ln( Σ e^(qᵢ/b) )
///
/// `√(s·s*)` is a damping term. It dominates at low `s`, deepening thin markets so a book is
/// tradeable without a large seed, and becomes negligible once `s ≫ s*`, converging to standard
/// LS-LMSR with `b = α·s`. Setting `s* = 0` collapses this to pure LS-LMSR exactly, which is what
/// {referenceLsLmsr} in the test suite cross-checks against.
///
/// ## Why this is solvent
///
/// `b(0) = 0 ⟹ C(0) = 0`, so the collateral collected over a market's life is exactly `C(q)` — the
/// path integral of a cost function depends only on its endpoints — while the maximum possible
/// payout is `max(qᵢ)`. Section "Numerically stable form" below shows `C(q) > max(qᵢ)` identically,
/// so the market is over-collateralised by construction rather than by parameter tuning.
///
/// This is the property a parimutuel pool cannot offer and the reason for the rule that no positive
/// `b₀` offset may ever be introduced without separately funding `b₀·ln(n)`: `b₀ > 0` makes
/// `C(0) > 0`, and that gap is an unfunded liability.
///
/// ## Numerically stable form (mandatory)
///
/// `Σ e^(qᵢ/b)` is never computed directly — with `q` in WAD and a thin book it overflows. Instead,
/// with `m = max(qᵢ)`:
///
///     C(q) = m + b · ln( 1 + Σ_{i ≠ argmax} e^((qᵢ − m)/b) )
///
/// Every exponent is `≤ 0`, so `exp` cannot overflow at any `α`. This identity is also the solvency
/// proof: the second term is strictly positive, therefore `C(q) > max(qᵢ)`.
///
/// ## Prices
///
/// Differentiating for general `b(s)` — note `∂s/∂qᵢ = 1`, so `b` itself moves with every trade:
///
///     σ     = softmax(qᵢ / b)
///     H(σ)  = −Σ σᵢ·ln(σᵢ)                    Shannon entropy, ≥ 0
///     b'(s) = α · (1 + ½·√(s*/s))
///     pᵢ    = σᵢ + b'(s)·H(σ)
///     Σpᵢ   = 1 + n·b'(s)·H(σ)
///
/// Two consequences worth stating, because they are guarantees rather than hopes:
///
///  - `Σpᵢ ≥ 1` iff `b'(s) ≥ 0`, and `b' > 0` everywhere on this curve. The no-free-complete-set
///    property therefore holds by construction. This is also why no split/merge or complete-set
///    mint path may exist: `Σpᵢ > 1` means an external mint-at-par would let anyone mint a set for
///    1 and sell it to the curve for more.
///  - `pᵢ = σᵢ + b'·H > 0`, so `C` is strictly monotone in every coordinate and no free-share
///    direction exists.
///
/// Prices are deliberately NOT plain softmax; `b` depends on `q`, and the `b'·H` term is exactly
/// the vig that pays for the liquidity.
///
/// ## Deviation from the brief: PRBMath, not Solady
///
/// The brief names Solady's FixedPointMathLib. This uses PRBMath `SD59x18` instead, which is
/// already vendored here and is what {LMSRMath} — the engine this replaces — is written against.
/// The requirement that actually matters is "do not hand-roll fixed-point logs", and PRBMath
/// satisfies it with an audited `ln`/`exp`/`sqrt`. Introducing a second fixed-point library to a
/// repo that already has one buys nothing and doubles the surface that has to be trusted.
///
/// ## Rounding
///
/// All rounding favours the contract: costs up, proceeds down. The margin is relative rather than a
/// single wei, because a single wei does not cover the error that matters here. `C` is evaluated as
/// `b·ln(…)` with `b` as large as ~1e23; a 1-wei error in `ln` is amplified by `b` into ~1e5 wei of
/// absolute error. {_DUST_INV} sets the margin at 1e-12 relative, which is many orders above
/// PRBMath's error and far below one base unit of any real collateral.
library LsLmsr {
    /// @dev Relative safety margin applied to every directed rounding, as a reciprocal: 1e-12.
    uint256 private constant _DUST_INV = 1e12;

    /// @dev Fixed-point one.
    uint256 private constant _WAD = 1e18;

    /// @notice Outcome count ceiling. Larger sets decompose into separate binary markets.
    uint256 internal constant MAX_OUTCOMES = 4;

    /// @dev `q` is empty, so there is no cost function to evaluate.
    error EmptyOutcomes();
    /// @dev A share count exceeded the range where fixed-point evaluation stays sound.
    error QuantityOutOfRange();

    /// @dev Largest single `qᵢ` accepted. `b` and `C` scale with `s`, and this keeps every
    ///      intermediate inside SD59x18 with room to spare even at `n = MAX_OUTCOMES`.
    uint256 internal constant MAX_Q = 1e30;

    // ---------------------------------------------------------------- liquidity

    /// @notice `b(s) = α·(s + √(s·s*))`, the liquidity parameter at total shares `s`.
    function b(uint256 s, uint256 alpha, uint256 sStar) internal pure returns (uint256) {
        return uint256(_b(s, alpha, sStar).unwrap());
    }

    /// @notice `b'(s) = α·(1 + ½·√(s*/s))`, the marginal liquidity. Reverts at `s = 0`, where the
    ///         curve has a vertical tangent and quoted spreads diverge — the reason for `sMin`.
    function bPrime(uint256 s, uint256 alpha, uint256 sStar) internal pure returns (uint256) {
        return uint256(_bPrime(s, alpha, sStar).unwrap());
    }

    function _b(uint256 s, uint256 alpha, uint256 sStar) private pure returns (SD59x18) {
        SD59x18 sFp = sd(int256(s));
        if (sStar == 0) return sd(int256(alpha)).mul(sFp);
        return sd(int256(alpha)).mul(sFp.add(sFp.mul(sd(int256(sStar))).sqrt()));
    }

    function _bPrime(uint256 s, uint256 alpha, uint256 sStar) private pure returns (SD59x18) {
        SD59x18 a = sd(int256(alpha));
        if (sStar == 0) return a;
        // α·(1 + ½·√(s*/s))
        SD59x18 ratio = sd(int256(sStar)).div(sd(int256(s)));
        return a.mul(UNIT.add(ratio.sqrt().div(sd(2e18))));
    }

    // ---------------------------------------------------------------- cost

    /// @notice `C(q)`, the total collateral a market has taken in to reach state `q`.
    /// @dev Exact at `q = 0`: returns 0 without touching the fixed-point path, which keeps the
    ///      `C(0) == 0` invariant a fact rather than a rounding accident.
    function cost(uint256[] memory q, uint256 alpha, uint256 sStar) internal pure returns (uint256) {
        SD59x18 c = _cost(q, alpha, sStar);
        return c.unwrap() <= 0 ? 0 : uint256(c.unwrap());
    }

    /// @dev Total, maximum and the index attaining it, in one pass. Returned together because every
    ///      entry point needs all three and the stack will not carry them as separate locals.
    function _stats(uint256[] memory q) private pure returns (uint256 s, uint256 m, uint256 maxIdx) {
        uint256 n = q.length;
        if (n == 0) revert EmptyOutcomes();
        for (uint256 i; i < n; ++i) {
            if (q[i] > MAX_Q) revert QuantityOutOfRange();
            s += q[i];
            if (q[i] > m) {
                m = q[i];
                maxIdx = i;
            }
        }
    }

    function _cost(uint256[] memory q, uint256 alpha, uint256 sStar) private pure returns (SD59x18) {
        (uint256 s, uint256 m, uint256 maxIdx) = _stats(q);
        if (s == 0) return ZERO;
        return _logSumExp(q, _b(s, alpha, sStar), m, maxIdx);
    }

    /// @dev `m + b·ln(1 + Σ_{i≠argmax} e^((qᵢ−m)/b))`, split out from {_cost} so that `alpha`,
    ///      `sStar` and `s` are off the stack before the loop runs. PRBMath's operators are
    ///      function calls and consume stack of their own; without this the loop does not compile
    ///      under the non-IR pipeline this repo builds with.
    ///
    ///      The sum skips exactly ONE index attaining the max. A second outcome equal to `m` is not
    ///      skipped and correctly contributes e^0 = 1.
    function _logSumExp(uint256[] memory q, SD59x18 bFp, uint256 m, uint256 maxIdx)
        private
        pure
        returns (SD59x18)
    {
        SD59x18 mFp = sd(int256(m));
        SD59x18 acc = ZERO;
        for (uint256 i; i < q.length; ++i) {
            if (i == maxIdx) continue;
            acc = acc.add(sd(int256(q[i])).sub(mFp).div(bFp).exp());
        }
        return mFp.add(bFp.mul(UNIT.add(acc).ln()));
    }

    /// @dev `σ = softmax(qᵢ/b)`, evaluated shifted by the maximum so no exponent is positive.
    /// @return sigma The normalised weights.
    /// @return z The normaliser, `Σ e^((qᵢ−m)/b)`, returned because it is also exactly the term
    ///         {_logSumExp} builds: `C(q) = m + b·ln(z)`. Handing it back lets a caller that needs
    ///         both prices and cost pay for the exponentials once. See {pricesAndCost}.
    function _softmax(uint256[] memory q, SD59x18 bFp, uint256 m, uint256 maxIdx)
        private
        pure
        returns (SD59x18[] memory sigma, SD59x18 z)
    {
        uint256 n = q.length;
        sigma = new SD59x18[](n);
        SD59x18 mFp = sd(int256(m));
        for (uint256 i; i < n; ++i) {
            sigma[i] = i == maxIdx ? UNIT : sd(int256(q[i])).sub(mFp).div(bFp).exp();
            z = z.add(sigma[i]);
        }
        uint256 tot;
        for (uint256 i; i < n; ++i) {
            sigma[i] = sigma[i].div(z);
            tot += uint256(sigma[i].unwrap());
        }

        // Force Σσ to exactly WAD by putting the residual on the max index.
        //
        // Each division truncates, so Σσ lands a wei or two below 1 and `Σp = Σσ + n·b'·H` slips
        // just under WAD — which would make the no-free-complete-set invariant unassertable even
        // though nothing is mispriced, since trades price off `C` and never off this vector. The
        // max index absorbs it because it is the largest and least sensitive term.
        if (tot < _WAD) {
            sigma[maxIdx] = sd(sigma[maxIdx].unwrap() + int256(_WAD - tot));
        } else if (tot > _WAD) {
            sigma[maxIdx] = sd(sigma[maxIdx].unwrap() - int256(tot - _WAD));
        }
    }

    /// @dev Shannon entropy `H(σ) = −Σ σᵢ·ln σᵢ`. Terms where `σᵢ` has underflowed to zero are
    ///      skipped, which is correct rather than merely convenient: `σ·ln σ → 0` as `σ → 0`.
    function _entropy(SD59x18[] memory sigma) private pure returns (SD59x18 h) {
        for (uint256 i; i < sigma.length; ++i) {
            if (sigma[i].unwrap() > 0) h = h.sub(sigma[i].mul(sigma[i].ln()));
        }
    }

    // ---------------------------------------------------------------- prices

    /// @notice Analytic marginal prices `pᵢ = σᵢ + b'·H`.
    /// @dev The test oracle. {LsLmsrQuote} in the test suite cross-checks it against a central
    ///      difference of {cost}; agreement to ~1e-13 is what proves `ln`, `exp`, `sqrt` and the
    ///      log-sum-exp shift are all wired correctly, which no invariant test would catch.
    function prices(uint256[] memory q, uint256 alpha, uint256 sStar)
        internal
        pure
        returns (uint256[] memory p)
    {
        (p,) = pricesAndCost(q, alpha, sStar);
    }

    /// @notice Marginal prices at `q` **and** `C(q)`, from a single pass over the exponentials.
    ///
    /// @dev Every trade needs both: the cost to charge, and the price vector the spread is
    ///      derived from. Computed separately they evaluate `e^((qᵢ−m)/b)` for every outcome
    ///      twice, and the exponential is the most expensive operation in this library by a wide
    ///      margin — measurably more than the storage writes a trade performs.
    ///
    ///      The identity that makes one pass enough is that the softmax normaliser IS the
    ///      log-sum-exp argument: `z = Σ e^((qᵢ−m)/b)`, so `C(q) = m + b·ln(z)`. {_softmax} sets
    ///      the maximum term to `UNIT` and sums in index order; {_logSumExp} skips the maximum and
    ///      adds `UNIT` at the end. Fixed-point addition is exact, so both reach the same `z` and
    ///      this returns a bit-identical cost — asserted in the test suite rather than assumed.
    function pricesAndCost(uint256[] memory q, uint256 alpha, uint256 sStar)
        internal
        pure
        returns (uint256[] memory p, SD59x18 c)
    {
        (uint256 s, uint256 m, uint256 maxIdx) = _stats(q);
        // At s = 0 there is no defined price: b' diverges. Callers enforce s >= sMin.
        if (s == 0) revert QuantityOutOfRange();

        SD59x18 bFp = _b(s, alpha, sStar);
        (SD59x18[] memory sigma, SD59x18 z) = _softmax(q, bFp, m, maxIdx);
        c = sd(int256(m)).add(bFp.mul(z.ln()));

        SD59x18 lift = _bPrime(s, alpha, sStar).mul(_entropy(sigma));

        p = new uint256[](q.length);
        for (uint256 i; i < q.length; ++i) {
            int256 v = sigma[i].add(lift).unwrap();
            p[i] = v <= 0 ? 0 : uint256(v);
        }
    }

    // ---------------------------------------------------------------- trades

    /// @notice Cost to buy `sh` shares of outcome `i`. Rounded UP. This is a long position.
    function costToBuy(uint256[] memory q, uint256 alpha, uint256 sStar, uint256 i, uint256 sh)
        internal
        pure
        returns (uint256)
    {
        return costToBuyFrom(_cost(q, alpha, sStar), q, alpha, sStar, i, sh);
    }

    /// @notice {costToBuy}, reusing a `C(q)` the caller already has.
    /// @dev Paired with {pricesAndCost}: a trade needs the price vector anyway, and that call
    ///      produces `C(q)` for free. Passing it here removes the second evaluation of the
    ///      opening state — one whole pass over the exponentials per trade.
    function costToBuyFrom(
        SD59x18 c0,
        uint256[] memory q,
        uint256 alpha,
        uint256 sStar,
        uint256 i,
        uint256 sh
    ) internal pure returns (uint256) {
        if (sh == 0) return 0;
        q[i] += sh;
        SD59x18 c1 = _cost(q, alpha, sStar);
        q[i] -= sh; // restore: `q` is the caller's array, not a copy
        return _up(c1.sub(c0));
    }

    /// @notice Proceeds from selling `sh` shares of outcome `i`. Rounded DOWN.
    function proceedsToSell(uint256[] memory q, uint256 alpha, uint256 sStar, uint256 i, uint256 sh)
        internal
        pure
        returns (uint256)
    {
        return proceedsToSellFrom(_cost(q, alpha, sStar), q, alpha, sStar, i, sh);
    }

    /// @notice {proceedsToSell}, reusing a `C(q)` the caller already has. See {costToBuyFrom}.
    function proceedsToSellFrom(
        SD59x18 c0,
        uint256[] memory q,
        uint256 alpha,
        uint256 sStar,
        uint256 i,
        uint256 sh
    ) internal pure returns (uint256) {
        q[i] -= sh;
        SD59x18 c1 = _cost(q, alpha, sStar);
        q[i] += sh;
        return _down(c0.sub(c1));
    }

    /// @notice Cost to buy `sh` shares of every outcome EXCEPT `i`. Rounded UP.
    /// @dev This is the short. It pays 1 per share exactly when `i` loses, because the outcomes are
    ///      exhaustive so some `j ≠ i` must win. There is deliberately no separate short primitive:
    ///      a synthetic short would need its own collateral rules, whereas this is just a basket of
    ///      longs and inherits solvency from the same `C(q) ≥ max(qᵢ)` argument.
    function costToBuyComplement(uint256[] memory q, uint256 alpha, uint256 sStar, uint256 i, uint256 sh)
        internal
        pure
        returns (uint256)
    {
        return costToBuyComplementFrom(_cost(q, alpha, sStar), q, alpha, sStar, i, sh);
    }

    /// @notice {costToBuyComplement}, reusing a `C(q)` the caller already has. See {costToBuyFrom}.
    function costToBuyComplementFrom(
        SD59x18 c0,
        uint256[] memory q,
        uint256 alpha,
        uint256 sStar,
        uint256 i,
        uint256 sh
    ) internal pure returns (uint256) {
        if (sh == 0) return 0;
        uint256 n = q.length;
        for (uint256 j; j < n; ++j) {
            if (j != i) q[j] += sh;
        }
        SD59x18 c1 = _cost(q, alpha, sStar);
        for (uint256 j; j < n; ++j) {
            if (j != i) q[j] -= sh;
        }
        return _up(c1.sub(c0));
    }

    // ---------------------------------------------------------------- rounding

    /// @dev Round a charge UP, and never to zero.
    ///
    /// A trade small enough that `ΔC` truncates to zero must still cost something: returning 0
    /// hands out shares for free, and repeating it is an unbounded drain. Callers short-circuit
    /// `sh == 0` before reaching here, so a non-positive value at this point means a real but
    /// sub-wei charge, which rounds to the smallest non-zero one.
    function _up(SD59x18 v) private pure returns (uint256) {
        int256 raw = v.unwrap();
        if (raw <= 0) return 1;
        uint256 x = uint256(raw);
        return x + x / _DUST_INV + 1;
    }

    function _down(SD59x18 v) private pure returns (uint256) {
        int256 raw = v.unwrap();
        if (raw <= 0) return 0;
        uint256 x = uint256(raw);
        uint256 margin = x / _DUST_INV + 1;
        return x > margin ? x - margin : 0;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SD59x18, sd, ZERO, UNIT} from "@prb/math/src/SD59x18.sol";
import {LsLmsr} from "../src/libraries/LsLmsr.sol";

/// @title LsLmsrTest
/// @notice The damped LS-LMSR library, tested in isolation before any market logic exists.
///
/// @dev Organised in the four tiers the implementation brief calls for, because they fail for
///      different reasons and a failure in each means something different:
///
///        Tier 1 — provable invariants. A failure is a code bug, never a design flaw.
///        Tier 2 — precision. This is where a fixed-point implementation actually fails.
///        Tier 3 — behavioural. The curve does what a market maker needs it to do.
///        Tier 4 — equivalence against a deliberately naive reference.
///
///      The highest-signal test in the file is {test_pricesAnalyticMatchNumeric}: it is the only
///      one that catches a wrong `ln`, `exp`, `sqrt`, or a mis-shifted log-sum-exp, all of which
///      Tier 1 sails straight past because a wrong-but-monotone cost function still satisfies every
///      invariant.
contract LsLmsrTest is Test {
    uint256 constant WAD = 1e18;

    /// Binary default from the brief.
    uint256 constant ALPHA2 = 0.025e18;
    /// Damping scale. `0` collapses the curve to pure LS-LMSR, which Tier 4 relies on.
    uint256 constant S_STAR = 2000e18;

    /// @dev Step for numeric differentiation: 0.001 shares, as specified.
    int256 constant EPS = 1e15;

    /// @dev Floor on total shares for price assertions.
    ///
    /// `b'(s) = α(1 + ½√(s*/s)) → ∞` as `s → 0`, so `pᵢ = σᵢ + b'·H` eventually exceeds 1 and the
    /// `pᵢ ≤ WAD` invariant genuinely breaks — at `s ≈ 0.645e18` for the binary defaults. That is a
    /// property of the curve, not a bug, and it is precisely what `sMin` exists to prevent. Every
    /// price test therefore stays at or above one whole share, and the market contract must enforce
    /// the same floor at creation.
    uint256 constant S_MIN = 1e18;

    // ------------------------------------------------------------------ helpers

    function _q(uint256 a, uint256 b_) internal pure returns (uint256[] memory q) {
        q = new uint256[](2);
        q[0] = a;
        q[1] = b_;
    }

    function _q(uint256 a, uint256 b_, uint256 c) internal pure returns (uint256[] memory q) {
        q = new uint256[](3);
        q[0] = a;
        q[1] = b_;
        q[2] = c;
    }

    function _q(uint256 a, uint256 b_, uint256 c, uint256 d) internal pure returns (uint256[] memory q) {
        q = new uint256[](4);
        q[0] = a;
        q[1] = b_;
        q[2] = c;
        q[3] = d;
    }

    function _sum(uint256[] memory v) internal pure returns (uint256 t) {
        for (uint256 i; i < v.length; ++i) {
            t += v[i];
        }
    }

    function _max(uint256[] memory v) internal pure returns (uint256 m) {
        for (uint256 i; i < v.length; ++i) {
            if (v[i] > m) m = v[i];
        }
    }

    /// @dev `α` for `n` outcomes, per the brief: 0.025 binary, else 0.035/(n·ln n).
    function _alphaFor(uint256 n) internal pure returns (uint256) {
        if (n == 2) return ALPHA2;
        SD59x18 nn = sd(int256(n * WAD));
        return uint256(sd(0.035e18).div(nn.mul(nn.ln())).unwrap());
    }

    /// @notice Marginal price by CENTRAL difference: `[C(q+εeᵢ) − C(q−εeᵢ)] / 2ε`.
    ///
    /// @dev The brief specifies a forward difference at ε = 1e15 and a tolerance of 1e12 wad. Those
    ///      two numbers are inconsistent: forward difference has O(ε·C'') error, which at this ε
    ///      measures 1.249e-6 at max-entropy points — above the 1e-6 tolerance it is checked
    ///      against, so correct code would fail. Central difference is O(ε²) and measures 4.7e-13
    ///      at the same point, roughly 10⁴ tighter, which makes the cross-check meaningful instead
    ///      of marginal.
    function _priceNumeric(uint256[] memory q, uint256 alpha, uint256 sStar, uint256 i)
        internal
        pure
        returns (int256)
    {
        uint256 e = uint256(EPS);
        require(q[i] >= e, "central difference needs headroom below q_i");
        q[i] += e;
        int256 up = int256(LsLmsr.cost(q, alpha, sStar));
        q[i] -= 2 * e;
        int256 dn = int256(LsLmsr.cost(q, alpha, sStar));
        q[i] += e;
        return ((up - dn) * int256(WAD)) / int256(2 * e);
    }

    /// @notice Deliberately naive LS-LMSR: `b = α·s` hardcoded, `Σe^(qᵢ/b)` computed directly with
    ///         no max-shift.
    /// @dev Tier 4's whole value is that this shares no code with the library. If it agreed because
    ///      it called the same helpers the test would prove nothing; computing the sum unshifted is
    ///      what actually validates the log-sum-exp rearrangement. Only safe for modest `q/b`, so
    ///      callers keep the ratio small.
    function _referenceLsLmsr(uint256[] memory q, uint256 alpha) internal pure returns (uint256) {
        uint256 s = _sum(q);
        if (s == 0) return 0;
        SD59x18 b = sd(int256(alpha)).mul(sd(int256(s)));
        SD59x18 acc = ZERO;
        for (uint256 i; i < q.length; ++i) {
            acc = acc.add(sd(int256(q[i])).div(b).exp());
        }
        return uint256(b.mul(acc.ln()).unwrap());
    }

    // ================================================================== TIER 1
    // Provable invariants. A failure here is a code bug, not a design flaw.

    function test_costOfZeroIsZero() public pure {
        assertEq(LsLmsr.cost(_q(0, 0), ALPHA2, S_STAR), 0, "C(0) must be exactly 0");
        assertEq(LsLmsr.cost(_q(0, 0, 0), _alphaFor(3), S_STAR), 0);
        assertEq(LsLmsr.cost(_q(0, 0, 0, 0), _alphaFor(4), S_STAR), 0);
        // b(0) = 0 is the reason, and it is what makes the market self-funding: were C(0) > 0 the
        // difference would be an unfunded liability on day one.
        assertEq(LsLmsr.b(0, ALPHA2, S_STAR), 0, "b(0) must be 0");
    }

    function testFuzz_costDominatesMaxPayout(uint256 a, uint256 b_, uint256 alpha) public pure {
        a = bound(a, 0, 1e24);
        b_ = bound(b_, 0, 1e24);
        alpha = bound(alpha, 1e15, 1e17);
        uint256[] memory q = _q(a, b_);
        // The solvency invariant, stated as the property that matters: collateral taken in (C)
        // always covers the largest possible payout (max qᵢ).
        assertGe(LsLmsr.cost(q, alpha, S_STAR), _max(q), "C(q) >= max(q_i) -- solvency");
    }

    function testFuzz_pricesSumAtLeastOne(uint256 a, uint256 b_, uint256 alpha) public pure {
        a = bound(a, 0, 1e24);
        b_ = bound(b_, 0, 1e24);
        vm.assume(a + b_ >= S_MIN);
        alpha = bound(alpha, 1e15, 1e17);
        uint256[] memory p = LsLmsr.prices(_q(a, b_), alpha, S_STAR);
        // Σp < 1 would let someone buy every outcome for less than the guaranteed payout.
        assertGe(_sum(p), WAD, "sum(p) >= 1 -- no free complete set");
    }

    function testFuzz_eachPriceInRange(uint256 a, uint256 b_, uint256 c) public pure {
        a = bound(a, 0, 1e24);
        b_ = bound(b_, 0, 1e24);
        c = bound(c, 0, 1e24);
        vm.assume(a + b_ + c >= S_MIN);
        uint256[] memory q = _q(a, b_, c);
        uint256[] memory p = LsLmsr.prices(q, _alphaFor(3), S_STAR);
        for (uint256 i; i < p.length; ++i) {
            assertLe(p[i], WAD, "p_i <= 1");
        }

        // `pᵢ > 0` holds in exact arithmetic but is NOT representable: at extreme skew the exponent
        // falls below -41.45 and `exp` underflows to zero, so a displayed price of 0 is honest —
        // the true price really is below 1e-18. Asserting `p > 0` would be asserting a property of
        // the reals, not of the contract.
        //
        // What must actually hold is the economic version: buying is never free. That is enforced
        // by rounding, not by the price vector, so it is checked here directly.
        for (uint256 i; i < q.length; ++i) {
            assertGt(
                LsLmsr.costToBuy(q, _alphaFor(3), S_STAR, i, 1e12),
                0,
                "no free share direction -- buying always costs"
            );
        }
    }

    /// @dev Monotonicity, stated as fixed point can actually deliver it.
    ///
    /// `C(q+Δ) ≥ C(q)` is exact in the reals. Evaluated in 18-decimal fixed point it is not: a `Δ`
    /// whose true cost is a fraction of a wei can move the computed value DOWN by a few tens of wei
    /// — measured at 44 wei for `Δ = 256` wei on a 100-share book. Asserting the exact form would be
    /// asserting a property of the reals rather than of the contract.
    ///
    /// The economic content is preserved elsewhere and is what matters: {testFuzz_singleWeiTradeIsNeverFree}
    /// proves no `Δ` is ever free, so this direction cannot be farmed.
    function testFuzz_costIsMonotoneWithinNoise(uint256 a, uint256 b_, uint256 delta, uint256 i) public pure {
        a = bound(a, 0, 1e24);
        b_ = bound(b_, 0, 1e24);
        delta = bound(delta, 0, 1e24);
        i = bound(i, 0, 1);
        uint256[] memory q = _q(a, b_);
        uint256 before = LsLmsr.cost(q, ALPHA2, S_STAR);
        q[i] += delta;
        assertGe(LsLmsr.cost(q, ALPHA2, S_STAR) + 1e6, before, "C non-decreasing up to noise");
    }

    /// @dev And strictly monotone once the trade is large enough for its cost to be representable.
    ///
    /// The bounds are the point of the test rather than incidental, and the reason is a precision
    /// limit rather than a tolerance choice. At a 1000× skew the internal `Σ_{i≠argmax} e^((qᵢ−m)/b)`
    /// term evaluates to about 22 wei — barely one significant digit — so a one-share trade perturbs
    /// it by 0.0008 wei and disappears entirely. No implementation at 18 decimals can be strictly
    /// monotone there; the deep campaign found exactly that case at run 1,237 of 100,000.
    ///
    /// Confining the book to a single order of magnitude keeps every case in the regime real markets
    /// occupy, where strictness is a claim that can actually be made. The degenerate regime is
    /// covered instead by {testFuzz_singleWeiTradeIsNeverFree}, which is the property that protects
    /// money and which holds everywhere.
    function testFuzz_costIsStrictlyMonotoneForRealTrades(uint256 a, uint256 b_, uint256 delta, uint256 i)
        public
        pure
    {
        a = bound(a, 1e21, 1e22);
        b_ = bound(b_, 1e21, 1e22);
        delta = bound(delta, 1e18, 1e24); // one whole share and up
        i = bound(i, 0, 1);
        uint256[] memory q = _q(a, b_);
        uint256 before = LsLmsr.cost(q, ALPHA2, S_STAR);
        q[i] += delta;
        assertGt(LsLmsr.cost(q, ALPHA2, S_STAR), before, "C strictly increases for a real trade");
    }

    // ================================================================== TIER 2
    // Precision. This is where it will actually fail.

    /// @notice The cross-check the brief calls the highest-signal test, and it is.
    function test_pricesAnalyticMatchNumeric() public pure {
        uint256[][] memory cases = new uint256[][](5);
        cases[0] = _q(1000e18, 1000e18); // max entropy: worst case for the difference
        cases[1] = _q(1500e18, 500e18);
        cases[2] = _q(50e18, 50e18); // thin book, b' large
        cases[3] = _q(800e18, 700e18, 500e18);
        cases[4] = _q(400e18, 300e18, 200e18, 100e18);

        for (uint256 c; c < cases.length; ++c) {
            uint256[] memory q = cases[c];
            uint256 alpha = _alphaFor(q.length);
            uint256[] memory analytic = LsLmsr.prices(q, alpha, S_STAR);
            for (uint256 i; i < q.length; ++i) {
                int256 numeric = _priceNumeric(q, alpha, S_STAR, i);
                // 1e12 wad = 1e-6 absolute, the brief's tolerance. Central difference clears it by
                // about six orders of magnitude; anything close to the bound means a broken
                // transcendental, not accumulated float error.
                assertApproxEqAbs(uint256(numeric), analytic[i], 1e12, "analytic vs numeric price");
            }
        }
    }

    function test_roundTripNeverPaysOut() public pure {
        uint256[] memory q = _q(1000e18, 1000e18);
        uint256 sh = 25e18;
        uint256 paid = LsLmsr.costToBuy(q, ALPHA2, S_STAR, 0, sh);
        q[0] += sh;
        uint256 got = LsLmsr.proceedsToSell(q, ALPHA2, S_STAR, 0, sh);
        // Buying and immediately selling must be a loss, with no spread applied at all. If this
        // ever inverted, the curve itself would be a money pump.
        assertLt(got, paid, "buy then sell must lose money even with zero spread");
    }

    function testFuzz_roundTripNeverPaysOut(uint256 a, uint256 b_, uint256 sh) public pure {
        a = bound(a, 1e18, 1e24);
        b_ = bound(b_, 1e18, 1e24);
        sh = bound(sh, 1e12, 1e22);
        uint256[] memory q = _q(a, b_);
        uint256 paid = LsLmsr.costToBuy(q, ALPHA2, S_STAR, 0, sh);
        q[0] += sh;
        uint256 got = LsLmsr.proceedsToSell(q, ALPHA2, S_STAR, 0, sh);
        assertLe(got, paid, "round trip must never pay out");
    }

    function test_chunkingIsNotCheaper() public pure {
        uint256[] memory q = _q(1000e18, 1000e18);

        uint256 whole = LsLmsr.costToBuy(q, ALPHA2, S_STAR, 0, 100e18);

        uint256 first = LsLmsr.costToBuy(q, ALPHA2, S_STAR, 0, 50e18);
        q[0] += 50e18;
        uint256 second = LsLmsr.costToBuy(q, ALPHA2, S_STAR, 0, 50e18);

        // Splitting a trade must not be a discount, or every trade becomes a loop. Equality to
        // within dust is the honest expectation: C is path independent, so the only difference is
        // the rounding margin applied twice instead of once.
        assertGe(first + second, whole, "two halves must not cost less than the whole");
        assertApproxEqRel(first + second, whole, 1e12, "path independence: chunks == whole");
    }

    // ================================================================== TIER 3
    // Behavioural.

    function test_buyingRaisesOwnPriceAndLowersOthers() public pure {
        uint256[] memory q = _q(1000e18, 1000e18, 1000e18);
        uint256 alpha = _alphaFor(3);
        uint256[] memory before = LsLmsr.prices(q, alpha, S_STAR);
        q[0] += 200e18;
        uint256[] memory afterP = LsLmsr.prices(q, alpha, S_STAR);

        assertGt(afterP[0], before[0], "buying outcome 0 must raise its price");
        assertLt(afterP[1], before[1], "and lower the others");
        assertLt(afterP[2], before[2]);
    }

    function test_dampingDeepensThinMarketsAndFadesOut() public pure {
        // Deepens: at low s the sqrt term dominates, so b is strictly larger than pure LS-LMSR.
        uint256 thin = 100e18;
        assertGt(LsLmsr.b(thin, ALPHA2, S_STAR), LsLmsr.b(thin, ALPHA2, 0), "damping must deepen a thin book");

        // Fades: as s grows the ratio converges to 1, which is what makes this LS-LMSR asymptotically
        // rather than a permanently different curve.
        //
        // The gap is `√(s*/s)`, so 1% agreement needs `s ≥ 1e4·s*` — at s = 1e24 the curves are
        // still 4.5% apart, which is convergence working as specified rather than failing.
        uint256 deep = 1e26;
        uint256 damped = LsLmsr.b(deep, ALPHA2, S_STAR);
        uint256 plain = LsLmsr.b(deep, ALPHA2, 0);
        assertApproxEqRel(damped, plain, 0.01e18, "b(s,s*)/b(s,0) -> 1 as s grows");
        assertGt(damped, plain, "but always from above");
    }

    function test_thinMarketIsTradeableWithoutALargeSeed() public pure {
        // The motive for the damping term: a book seeded with 10 shares per outcome still quotes a
        // finite, sane spread, so a market does not need a large subsidy to open.
        uint256[] memory q = _q(10e18, 10e18);
        uint256[] memory p = LsLmsr.prices(q, ALPHA2, S_STAR);
        uint256 vig = _sum(p) - WAD;
        assertLt(vig, 0.5e18, "a 20-share book must still quote under a 50% vig");
        assertGt(vig, 0, "and must still charge something");
    }

    // ================================================================== TIER 4
    // Fallback equivalence: s* = 0 must be pure LS-LMSR.

    function test_matchesNaiveReferenceWhenUndamped() public pure {
        uint256[][] memory cases = new uint256[][](4);
        cases[0] = _q(100e18, 100e18);
        cases[1] = _q(250e18, 90e18);
        cases[2] = _q(300e18, 300e18, 300e18);
        cases[3] = _q(120e18, 110e18, 100e18, 90e18);

        for (uint256 c; c < cases.length; ++c) {
            uint256[] memory q = cases[c];
            uint256 alpha = _alphaFor(q.length);
            // Tolerance is a few wei, not zero: the reference sums e^(qᵢ/b) unshifted while the
            // library sums e^((qᵢ−m)/b) and adds m back, so the two differ in their last bits by
            // construction. Agreement at this scale is what proves the rearrangement is right.
            assertApproxEqAbs(
                LsLmsr.cost(q, alpha, 0), _referenceLsLmsr(q, alpha), 1e6, "s*=0 must equal naive LS-LMSR"
            );
        }
    }

    function test_undampedPriceSumHasClosedForm() public pure {
        // Σpᵢ = 1 + n·α·H(σ) exactly, when b' = α. Computing H independently here is the point:
        // it checks the entropy term rather than trusting the same code that produced the prices.
        uint256[] memory q = _q(600e18, 400e18);
        uint256[] memory p = LsLmsr.prices(q, ALPHA2, 0);

        SD59x18 b = sd(int256(ALPHA2)).mul(sd(int256(_sum(q))));
        SD59x18 e0 = sd(int256(q[0])).div(b).exp();
        SD59x18 e1 = sd(int256(q[1])).div(b).exp();
        SD59x18 z = e0.add(e1);
        SD59x18 s0 = e0.div(z);
        SD59x18 s1 = e1.div(z);
        SD59x18 h = ZERO.sub(s0.mul(s0.ln())).sub(s1.mul(s1.ln()));
        uint256 expected = WAD + uint256(sd(int256(2 * ALPHA2)).mul(h).unwrap());

        assertApproxEqAbs(_sum(p), expected, 1e9, "sum(p) == 1 + n*alpha*H");
    }

    // ================================================================== complement

    function test_complementIsTheShortAndBinaryCollapsesToTheOtherSide() public pure {
        uint256[] memory q = _q(1200e18, 800e18);
        uint256 sh = 30e18;
        // For n = 2 shorting outcome 0 IS buying outcome 1 — same state change, so the costs must
        // be identical. Any divergence means the complement path is not building the basket right.
        assertEq(
            LsLmsr.costToBuyComplement(q, ALPHA2, S_STAR, 0, sh),
            LsLmsr.costToBuy(q, ALPHA2, S_STAR, 1, sh),
            "binary complement == buying the other side"
        );
    }

    function test_completeSetCostsMoreThanItPays() public pure {
        // The reason no split/merge vault may exist. Buying one of every outcome guarantees a payout
        // of exactly `sh`, and the curve must charge strictly more than that, or the mint path is
        // a risk-free withdrawal.
        uint256[] memory q = _q(1000e18, 1000e18, 1000e18);
        uint256 alpha = _alphaFor(3);
        uint256 sh = 10e18;

        uint256 c0 = LsLmsr.cost(q, alpha, S_STAR);
        for (uint256 i; i < 3; ++i) {
            q[i] += sh;
        }
        uint256 c1 = LsLmsr.cost(q, alpha, S_STAR);

        assertGt(c1 - c0, sh, "a complete set must cost more than it redeems");
    }

    function testFuzz_complementCostsMoreThanZeroAndLessThanFullSet(uint256 sh) public pure {
        sh = bound(sh, 1e15, 1e22);
        uint256[] memory q = _q(1000e18, 900e18, 800e18);
        uint256 alpha = _alphaFor(3);

        uint256 short0 = LsLmsr.costToBuyComplement(q, alpha, S_STAR, 0, sh);
        assertGt(short0, 0, "a short must cost something");

        uint256 c0 = LsLmsr.cost(q, alpha, S_STAR);
        for (uint256 i; i < 3; ++i) {
            q[i] += sh;
        }
        uint256 full = LsLmsr.cost(q, alpha, S_STAR) - c0;
        // Shorting one outcome buys n-1 legs; the full set buys n. It must be strictly cheaper.
        assertLt(short0, full, "short must cost less than the complete set");
    }

    // ================================================================== fuzz, weighted

    /// @dev Uniform random inputs will not find these bugs. The brief's weighting — max skew where
    ///      H → 0, `s` near the floor where b' is largest, and single-wei trades — is reproduced by
    ///      bounding into those regions deliberately.
    function testFuzz_maxSkewStaysSolvent(uint256 big, uint256 tiny, uint256 sStar) public pure {
        big = bound(big, 1e21, 1e24);
        tiny = bound(tiny, 1, 1e18);
        sStar = bound(sStar, 0, 1e24);
        uint256[] memory q = _q(big, tiny);
        assertGe(LsLmsr.cost(q, ALPHA2, sStar), big, "solvent at maximum skew");
    }

    function testFuzz_singleWeiTradeIsNeverFree(uint256 a, uint256 b_) public pure {
        a = bound(a, 1e18, 1e24);
        b_ = bound(b_, 1e18, 1e24);
        uint256[] memory q = _q(a, b_);
        // Rounding must favour the contract even at the smallest possible size, or a wei-sized
        // trade repeated becomes free shares.
        assertGt(LsLmsr.costToBuy(q, ALPHA2, S_STAR, 0, 1), 0, "1 wei of shares is never free");
    }

    function testFuzz_dampingIsAlwaysAtLeastUndamped(uint256 s, uint256 sStar) public pure {
        s = bound(s, 1e18, 1e26);
        sStar = bound(sStar, 0, 1e24);
        assertGe(LsLmsr.b(s, ALPHA2, sStar), LsLmsr.b(s, ALPHA2, 0), "damping never reduces b");
    }
}

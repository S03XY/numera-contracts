// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SD59x18} from "@prb/math/src/SD59x18.sol";
import {LsLmsr} from "../src/libraries/LsLmsr.sol";

/**
 * The fused price/cost pass must be BIT-IDENTICAL to computing the two separately.
 *
 * `pricesAndCost` exists to stop a trade evaluating `e^((qᵢ−m)/b)` for every outcome twice. It
 * gets away with that because the softmax normaliser is the log-sum-exp argument: `z = Σ e^(…)`,
 * so `C(q) = m + b·ln(z)`. The two routines build `z` in a different order — {_softmax} counts
 * the maximum term as `UNIT` in place, {_logSumExp} skips it and adds `UNIT` at the end — and the
 * claim is that fixed-point addition is exact, so both land on the same integer.
 *
 * "Close enough" is not good enough here. A one-wei difference in `C` would be a one-wei
 * difference in what a trader is charged, and the solvency assertion is an exact integer
 * comparison — so an approximation would eventually revert a legitimate trade rather than merely
 * misprice it. These tests therefore assert equality, never tolerance.
 */
contract LsLmsrFusionTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant ALPHA = 0.025e18;
    uint256 constant S_STAR = 2000e18;

    function _q(uint256 a, uint256 b) internal pure returns (uint256[] memory q) {
        q = new uint256[](2);
        q[0] = a;
        q[1] = b;
    }

    function _q3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory q) {
        q = new uint256[](3);
        q[0] = a;
        q[1] = b;
        q[2] = c;
    }

    // ------------------------------------------------------------------ cost

    function test_fusedCostMatchesStandalone_balanced() public pure {
        uint256[] memory q = _q(1000e18, 1000e18);
        (, SD59x18 fused) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);
        assertEq(uint256(fused.unwrap()), LsLmsr.cost(q, ALPHA, S_STAR));
    }

    function test_fusedCostMatchesStandalone_skewed() public pure {
        // The shift by the maximum is what keeps the exponentials in range, so the skewed case is
        // where an ordering difference between the two routines would show up first.
        uint256[] memory q = _q(19_000e18, 1000e18);
        (, SD59x18 fused) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);
        assertEq(uint256(fused.unwrap()), LsLmsr.cost(q, ALPHA, S_STAR));
    }

    function test_fusedCostMatchesStandalone_threeOutcomes() public pure {
        uint256[] memory q = _q3(800e18, 700e18, 500e18);
        uint256 alpha = uint256(0.035e18) / 3; // roughly the n-outcome default
        (, SD59x18 fused) = LsLmsr.pricesAndCost(q, alpha, S_STAR);
        assertEq(uint256(fused.unwrap()), LsLmsr.cost(q, alpha, S_STAR));
    }

    function testFuzz_fusedCostMatchesStandalone(uint256 a, uint256 b) public pure {
        a = bound(a, 1e18, 1e26);
        b = bound(b, 1e18, 1e26);
        uint256[] memory q = _q(a, b);
        (, SD59x18 fused) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);
        assertEq(uint256(fused.unwrap()), LsLmsr.cost(q, ALPHA, S_STAR));
    }

    // ---------------------------------------------------------------- prices

    function testFuzz_fusedPricesMatchStandalone(uint256 a, uint256 b) public pure {
        a = bound(a, 1e18, 1e26);
        b = bound(b, 1e18, 1e26);
        uint256[] memory q = _q(a, b);

        (uint256[] memory fused,) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);
        uint256[] memory standalone = LsLmsr.prices(q, ALPHA, S_STAR);

        assertEq(fused.length, standalone.length);
        for (uint256 i; i < fused.length; ++i) {
            assertEq(fused[i], standalone[i]);
        }
    }

    // ----------------------------------------------------------- trade deltas

    function testFuzz_costToBuyFromMatchesStandalone(uint256 a, uint256 b, uint256 sh) public pure {
        a = bound(a, 1e18, 1e24);
        b = bound(b, 1e18, 1e24);
        sh = bound(sh, 1, 1e24);
        uint256[] memory q = _q(a, b);

        (, SD59x18 c0) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);
        assertEq(LsLmsr.costToBuyFrom(c0, q, ALPHA, S_STAR, 0, sh), LsLmsr.costToBuy(q, ALPHA, S_STAR, 0, sh));
    }

    function testFuzz_proceedsToSellFromMatchesStandalone(uint256 a, uint256 b, uint256 sh) public pure {
        a = bound(a, 1e18, 1e24);
        b = bound(b, 1e18, 1e24);
        sh = bound(sh, 1, a - 1); // may only sell what the outcome actually carries
        uint256[] memory q = _q(a, b);

        (, SD59x18 c0) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);
        assertEq(
            LsLmsr.proceedsToSellFrom(c0, q, ALPHA, S_STAR, 0, sh),
            LsLmsr.proceedsToSell(q, ALPHA, S_STAR, 0, sh)
        );
    }

    function testFuzz_costToBuyComplementFromMatchesStandalone(uint256 a, uint256 b, uint256 sh) public pure {
        a = bound(a, 1e18, 1e24);
        b = bound(b, 1e18, 1e24);
        sh = bound(sh, 1, 1e24);
        uint256[] memory q = _q3(a, b, (a + b) / 2);

        uint256 alpha = uint256(0.035e18) / 3;
        (, SD59x18 c0) = LsLmsr.pricesAndCost(q, alpha, S_STAR);
        assertEq(
            LsLmsr.costToBuyComplementFrom(c0, q, alpha, S_STAR, 0, sh),
            LsLmsr.costToBuyComplement(q, alpha, S_STAR, 0, sh)
        );
    }

    // -------------------------------------------------------------- q hygiene

    function test_fusedPathLeavesQUntouched() public pure {
        // Every `*From` helper mutates the caller's array and restores it. A leak here would
        // corrupt the book on the very next read, silently.
        uint256[] memory q = _q(1000e18, 900e18);
        (, SD59x18 c0) = LsLmsr.pricesAndCost(q, ALPHA, S_STAR);

        LsLmsr.costToBuyFrom(c0, q, ALPHA, S_STAR, 0, 50e18);
        assertEq(q[0], 1000e18);
        assertEq(q[1], 900e18);

        LsLmsr.proceedsToSellFrom(c0, q, ALPHA, S_STAR, 0, 50e18);
        assertEq(q[0], 1000e18);
        assertEq(q[1], 900e18);
    }
}

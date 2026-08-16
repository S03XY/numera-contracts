// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMath} from "../../src/libraries/LMSRMath.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @notice Validates the LMSR math + PRBMath integration in isolation.
contract LMSRMathTest is Test {
    uint256 constant USDC = 1e6;

    function _zeros(uint256 n) internal pure returns (uint256[] memory q) {
        q = new uint256[](n);
    }

    // ----- subsidy / cost -----

    function test_cost_atZeroIsBLogN_binary() public pure {
        // C(0) = b*ln(2). b = 1000 USDC = 1e9 base units => 1e9 * 0.6931471806 ≈ 693.147181 USDC.
        uint256 b = 1000 * USDC;
        uint256 c = LMSRMath.cost(_zeros(2), b);
        assertApproxEqAbs(c, 693_147_181, 3); // in base units (6 dp), rounded up
    }

    function test_cost_atZeroIsBLogN_multi() public pure {
        // C(0) = b*ln(4) = 1e9 * 1.3862943611 ≈ 1386.294362 USDC.
        uint256 c = LMSRMath.cost(_zeros(4), 1000 * USDC);
        assertApproxEqAbs(c, 1_386_294_362, 3);
    }

    // ----- prices -----

    function test_prices_startUniform() public pure {
        uint256[] memory p = LMSRMath.prices(_zeros(2), 1000 * USDC);
        assertApproxEqAbs(p[0], 0.5e18, 1e6);
        assertApproxEqAbs(p[1], 0.5e18, 1e6);
    }

    function test_prices_shiftUpWhenOutcomeBought() public pure {
        // Buying "Yes" (outcome 1) shares raises its price; "No" falls. Prices still sum to ~1.
        uint256 b = 1000 * USDC;
        uint256[] memory q = _zeros(2);
        q[1] = 500 * USDC; // 500 Yes shares outstanding
        uint256[] memory p = LMSRMath.prices(q, b);
        assertGt(p[1], 0.5e18); // Yes above 50%
        assertLt(p[0], 0.5e18); // No below 50%
        assertApproxEqAbs(p[0] + p[1], Constants.WAD, 2);
    }

    function test_prices_multiSumToOne() public pure {
        uint256[] memory q = _zeros(3);
        q[0] = 300 * USDC;
        q[2] = 100 * USDC;
        uint256[] memory p = LMSRMath.prices(q, 800 * USDC);
        assertApproxEqAbs(p[0] + p[1] + p[2], Constants.WAD, 3);
        // Ordering follows q: q[0]=300 > q[2]=100 > q[1]=0  =>  p[0] > p[2] > p[1].
        assertGt(p[0], p[2]);
        assertGt(p[2], p[1]);
    }

    // ----- buy cost / sell refund -----

    function test_costToBuy_positiveAndBounded() public pure {
        // Buying `delta` shares costs between 0 and `delta` (a share never costs more than 1).
        uint256 b = 1000 * USDC;
        uint256[] memory q = _zeros(2);
        uint256 delta = 100 * USDC;
        uint256 c = LMSRMath.costToBuy(q, b, 1, delta);
        assertGt(c, 0);
        assertLt(c, delta); // a share never costs more than 1 collateral
        // Starting at 50c and buying 100 shares (delta/b = 0.1) pushes avg cost above 50c (~51.25c).
        assertGt(c, 50 * USDC);
        assertLt(c, 53 * USDC);
    }

    function test_buyThenSellRefundsLessThanPaid() public pure {
        // Round-trip must lose a little (rounding favours the pool) — never profit risk-free.
        uint256 b = 1000 * USDC;
        uint256[] memory q = _zeros(2);
        uint256 delta = 100 * USDC;

        uint256 paid = LMSRMath.costToBuy(q, b, 1, delta);
        q[1] += delta; // apply the buy
        uint256 refund = LMSRMath.refundToSell(q, b, 1, delta);

        assertLe(refund, paid); // no free money
        assertApproxEqRel(refund, paid, 1e12); // but very close (within 1e-6)
    }

    function test_costToBuy_doesNotMutateInput() public pure {
        uint256[] memory q = _zeros(2);
        q[0] = 10 * USDC;
        LMSRMath.costToBuy(q, 1000 * USDC, 1, 50 * USDC);
        assertEq(q[0], 10 * USDC); // restored
        assertEq(q[1], 0);
    }

    // ----- solvency invariant (fuzz): C(q) >= max q_i, so winners are always covered -----

    function testFuzz_costCoversWinner(uint64 q0, uint64 q1, uint32 bRaw) public pure {
        uint256 b = bound(uint256(bRaw), 1 * USDC, 1e6 * USDC);
        uint256[] memory q = new uint256[](2);
        q[0] = q0;
        q[1] = q1;
        uint256 c = LMSRMath.cost(q, b);
        assertGe(c, q[0]); // C(q) >= q_i for every outcome
        assertGe(c, q[1]);
    }

    /// @dev Incremental cost equals total-cost difference (rounding tolerance), proving the pot,
    ///      accumulated from per-trade costs, tracks C(q).
    function testFuzz_incrementalMatchesTotal(uint64 delta, uint32 bRaw) public pure {
        uint256 b = bound(uint256(bRaw), 10 * USDC, 1e5 * USDC);
        uint256 d = bound(uint256(delta), 1, 1e6 * USDC);
        uint256[] memory q = _zeros(2);

        uint256 c0 = LMSRMath.cost(q, b);
        uint256 incr = LMSRMath.costToBuy(q, b, 0, d);
        q[0] += d;
        uint256 c1 = LMSRMath.cost(q, b);

        // c1 - c0 ≈ incr (within a couple of base units from independent ceils)
        assertApproxEqAbs(c1 - c0, incr, 3);
    }
}

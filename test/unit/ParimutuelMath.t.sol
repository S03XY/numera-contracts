// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ParimutuelMath} from "../../src/libraries/ParimutuelMath.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/// @notice Unit tests for the parimutuel payout math. Positive, negative, edge, and invariant (fuzz).
contract ParimutuelMathTest is Test {
    using ParimutuelMath for uint256;

    uint256 constant USDC = 1e6; // 6-decimal unit, matching USDC

    // -------------------------------------------------------------------------
    // protocolFee / netPool
    // -------------------------------------------------------------------------

    function test_protocolFee_basic() public pure {
        // 2% of 1000 USDC = 20 USDC
        assertEq(ParimutuelMath.protocolFee(1000 * USDC, 200), 20 * USDC);
    }

    function test_protocolFee_zeroFee() public pure {
        assertEq(ParimutuelMath.protocolFee(1000 * USDC, 0), 0);
    }

    function test_protocolFee_zeroPool() public pure {
        assertEq(ParimutuelMath.protocolFee(0, 500), 0);
    }

    function test_netPool_removesFee() public pure {
        uint256 total = 1000 * USDC;
        uint256 net = ParimutuelMath.netPool(total, 200); // 2%
        assertEq(net, 980 * USDC);
        assertEq(net + ParimutuelMath.protocolFee(total, 200), total); // conservation
    }

    // -------------------------------------------------------------------------
    // winnerPayout
    // -------------------------------------------------------------------------

    function test_winnerPayout_soleWinnerGetsWholeNetPot() public pure {
        // One winner staked the entire winning pool -> receives the whole net pot.
        uint256 net = 980 * USDC;
        assertEq(ParimutuelMath.winnerPayout(100 * USDC, 100 * USDC, net), net);
    }

    function test_winnerPayout_proRataSplit() public pure {
        // Two winners: 30 and 70 of a 100 winning pool, net pot 200.
        uint256 net = 200 * USDC;
        uint256 a = ParimutuelMath.winnerPayout(30 * USDC, 100 * USDC, net);
        uint256 b = ParimutuelMath.winnerPayout(70 * USDC, 100 * USDC, net);
        assertEq(a, 60 * USDC);
        assertEq(b, 140 * USDC);
        assertEq(a + b, net); // exact, no dust here
    }

    function test_winnerPayout_zeroWinningPoolReturnsZero() public pure {
        // Degenerate: nobody bet the winning outcome -> caller must route to refunds.
        assertEq(ParimutuelMath.winnerPayout(100 * USDC, 0, 500 * USDC), 0);
    }

    function test_winnerPayout_zeroStakeReturnsZero() public pure {
        assertEq(ParimutuelMath.winnerPayout(0, 100 * USDC, 500 * USDC), 0);
    }

    function test_winnerPayout_roundsDownNeverOverpays() public pure {
        // 1 wei stake of a 3-wei winning pool against a 10-wei net pot -> 10/3 = 3 (floor).
        uint256 p1 = ParimutuelMath.winnerPayout(1, 3, 10);
        uint256 p2 = ParimutuelMath.winnerPayout(1, 3, 10);
        uint256 p3 = ParimutuelMath.winnerPayout(1, 3, 10);
        assertEq(p1, 3);
        // Sum of floored payouts must never exceed the net pot.
        assertLe(p1 + p2 + p3, 10);
    }

    function test_winnerPayout_noOverflowOnHugePools() public pure {
        // Full-precision mulDiv must not overflow even near uint256 max stake*net.
        uint256 huge = type(uint128).max;
        uint256 payout = ParimutuelMath.winnerPayout(huge, huge, huge);
        assertEq(payout, huge); // stake==pool -> whole net pot
    }

    // -------------------------------------------------------------------------
    // priceWad / oddsWad
    // -------------------------------------------------------------------------

    function test_priceWad_halfMarket() public pure {
        // Outcome holds 40 of a 100 pool -> price 0.4e18.
        assertEq(ParimutuelMath.priceWad(40 * USDC, 100 * USDC), 0.4e18);
    }

    function test_priceWad_emptyMarketIsZero() public pure {
        assertEq(ParimutuelMath.priceWad(0, 0), 0);
    }

    function test_priceWad_sumsToWad() public pure {
        // Binary market: prices of both outcomes sum to 1e18 (no dust for clean split).
        uint256 total = 100 * USDC;
        uint256 pYes = ParimutuelMath.priceWad(60 * USDC, total);
        uint256 pNo = ParimutuelMath.priceWad(40 * USDC, total);
        assertEq(pYes + pNo, Constants.WAD);
    }

    function test_oddsWad_basic() public pure {
        // Net pot 200, this outcome pool 100 -> 2.0x odds.
        assertEq(ParimutuelMath.oddsWad(100 * USDC, 200 * USDC), 2e18);
    }

    function test_oddsWad_emptyOutcomeIsZero() public pure {
        assertEq(ParimutuelMath.oddsWad(0, 200 * USDC), 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz invariants
    // -------------------------------------------------------------------------

    /// @dev Winners can never collectively be paid more than the net pot.
    function testFuzz_payoutsNeverExceedNetPot(uint128 stakeA, uint128 stakeB, uint128 net) public pure {
        uint256 pool = uint256(stakeA) + uint256(stakeB);
        vm.assume(pool > 0);
        uint256 payA = ParimutuelMath.winnerPayout(stakeA, pool, net);
        uint256 payB = ParimutuelMath.winnerPayout(stakeB, pool, net);
        assertLe(payA + payB, net);
    }

    /// @dev Fee never exceeds the pool; net + fee reconstructs the pool exactly.
    function testFuzz_feeConservation(uint128 total, uint16 feeBps) public pure {
        feeBps = uint16(bound(feeBps, 0, Constants.MAX_FEE_BPS));
        uint256 fee = ParimutuelMath.protocolFee(total, feeBps);
        uint256 net = ParimutuelMath.netPool(total, feeBps);
        assertLe(fee, total);
        assertEq(fee + net, total);
    }
}

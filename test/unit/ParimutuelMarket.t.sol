// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ParimutuelMarket} from "../../src/markets/ParimutuelMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../../src/mocks/MockFeeOnTransferERC20.sol";
import {MarketTypes} from "../../src/libraries/MarketTypes.sol";
import {Roles} from "../../src/access/Roles.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    ZeroAddress,
    InvalidOutcomeCount,
    FeeTooHigh,
    CloseTimeInPast,
    MarketNotFound,
    MarketNotTrading,
    MarketClosed,
    MarketNotClosed,
    MarketNotResolved,
    MarketNotInvalid,
    InvalidOutcome,
    AmountZero,
    AmountBelowMin,
    NothingToClaim,
    AlreadyClaimed,
    NotResolver
} from "../../src/libraries/Errors.sol";

/// @notice End-to-end unit tests for the parimutuel engine: create, bet, resolve, claim, refund,
///         fees, pausing, prices, and every negative path.
contract ParimutuelMarketTest is Test {
    ParimutuelMarket market;
    TrustedResolver resolver;
    MockERC20 usdc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");
    address feeTo = makeAddr("feeTo");

    uint64 closeTime;
    uint256 constant USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new ParimutuelMarket(address(this)); // test contract is admin (has all roles)
        resolver = new TrustedResolver(address(this)); // test contract holds RESOLVER_ROLE
        closeTime = uint64(block.timestamp + 1 days);

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who) internal {
        usdc.mint(who, 1_000_000 * USDC);
        vm.prank(who);
        usdc.approve(address(market), type(uint256).max);
    }

    function _create(uint32 outcomes, uint16 feeBps, uint256 minBet) internal returns (uint256 id) {
        id = market.createMarket(
            ParimutuelMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver),
                closeTime: closeTime,
                outcomeCount: outcomes,
                feeBps: feeBps,
                minBet: minBet,
                category: bytes32("SPORTS"),
                metadataHash: keccak256("Team A vs Team B")
            })
        );
    }

    function _createBinary() internal returns (uint256) {
        return _create(2, 0, 0);
    }

    function _bet(address who, uint256 id, uint256 outcome, uint256 amount) internal {
        vm.prank(who);
        market.placeBet(id, outcome, amount);
    }

    // ======================================================================
    // createMarket
    // ======================================================================

    function test_create_binaryStoresConfig() public {
        uint256 id = _create(2, 200, 5 * USDC);
        ParimutuelMarket.MarketView memory v = market.getMarket(id);
        assertEq(v.collateral, address(usdc));
        assertEq(v.resolver, address(resolver));
        assertEq(v.closeTime, closeTime);
        assertEq(v.outcomeCount, 2);
        assertEq(v.feeBps, 200);
        assertEq(v.minBet, 5 * USDC);
        assertEq(v.category, bytes32("SPORTS"));
        assertEq(uint8(v.status), uint8(MarketTypes.Status.Trading));
        assertTrue(v.bettingOpen);
        assertEq(market.marketCount(), 1);
    }

    function test_create_multiOutcome() public {
        uint256 id = _create(5, 0, 0);
        assertEq(market.getMarket(id).outcomeCount, 5);
    }

    function test_create_incrementsIds() public {
        assertEq(_create(2, 0, 0), 0);
        assertEq(_create(3, 0, 0), 1);
        assertEq(market.marketCount(), 2);
    }

    function test_create_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(market));
        emit ParimutuelMarket.MarketCreated(
            0,
            address(usdc),
            address(resolver),
            closeTime,
            2,
            200,
            5 * USDC,
            bytes32("SPORTS"),
            keccak256("Team A vs Team B"),
            address(this)
        );
        _create(2, 200, 5 * USDC);
    }

    // ---- negative ----

    function test_create_revertsZeroCollateral() public {
        vm.expectRevert(ZeroAddress.selector);
        market.createMarket(
            ParimutuelMarket.CreateParams(address(0), address(resolver), closeTime, 2, 0, 0, "", "")
        );
    }

    function test_create_revertsZeroResolver() public {
        vm.expectRevert(ZeroAddress.selector);
        market.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(0), closeTime, 2, 0, 0, "", "")
        );
    }

    function test_create_revertsTooFewOutcomes() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcomeCount.selector, 1, 2, 256));
        market.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 1, 0, 0, "", "")
        );
    }

    function test_create_revertsTooManyOutcomes() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcomeCount.selector, 257, 2, 256));
        market.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 257, 0, 0, "", "")
        );
    }

    function test_create_revertsFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1001, 1000));
        market.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 1001, 0, "", "")
        );
    }

    function test_create_revertsCloseInPast() public {
        uint64 past = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(CloseTimeInPast.selector, past, uint64(block.timestamp)));
        market.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), past, 2, 0, 0, "", "")
        );
    }

    function test_create_revertsForNonCreator() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.MARKET_CREATOR_ROLE
            )
        );
        market.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, 0, "", "")
        );
    }

    // ======================================================================
    // placeBet
    // ======================================================================

    function test_bet_updatesLedgersAndReturnsCredited() public {
        uint256 id = _createBinary();
        vm.prank(alice);
        uint256 credited = market.placeBet(id, 0, 100 * USDC);
        assertEq(credited, 100 * USDC);
        assertEq(market.outcomePool(id, 0), 100 * USDC);
        assertEq(market.getMarket(id).totalPool, 100 * USDC);
        assertEq(market.stakeOf(id, alice, 0), 100 * USDC);
        assertEq(market.totalStakeOf(id, alice), 100 * USDC);
        assertEq(usdc.balanceOf(address(market)), 100 * USDC);
    }

    function test_bet_multipleBettorsAndOutcomes() public {
        uint256 id = _create(3, 0, 0);
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 300 * USDC);
        _bet(carol, id, 2, 600 * USDC);
        assertEq(market.getMarket(id).totalPool, 1000 * USDC);
        assertEq(market.outcomePool(id, 1), 300 * USDC);
    }

    function test_bet_accumulatesSameOwnerSameOutcome() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 40 * USDC);
        _bet(alice, id, 0, 60 * USDC);
        assertEq(market.stakeOf(id, alice, 0), 100 * USDC);
    }

    function test_bet_emitsEvent() public {
        uint256 id = _createBinary();
        vm.expectEmit(true, true, true, true, address(market));
        emit ParimutuelMarket.BetPlaced(id, alice, 0, 100 * USDC, 100 * USDC, 100 * USDC);
        _bet(alice, id, 0, 100 * USDC);
    }

    function test_bet_respectsMinBet() public {
        uint256 id = _create(2, 0, 50 * USDC);
        _bet(alice, id, 0, 50 * USDC); // exactly min ok
        assertEq(market.stakeOf(id, alice, 0), 50 * USDC);
    }

    function test_bet_creditsActualReceivedForFeeOnTransfer() public {
        // Prove balance-delta accounting: a 1% fee-on-transfer token credits 99, not 100.
        MockFeeOnTransferERC20 fee = new MockFeeOnTransferERC20(100);
        fee.mint(alice, 1000e18);
        vm.prank(alice);
        fee.approve(address(market), type(uint256).max);

        uint256 id = market.createMarket(
            ParimutuelMarket.CreateParams(address(fee), address(resolver), closeTime, 2, 0, 0, "", "")
        );
        vm.prank(alice);
        uint256 credited = market.placeBet(id, 0, 100e18);
        assertEq(credited, 99e18);
        assertEq(market.outcomePool(id, 0), 99e18);
        assertEq(market.stakeOf(id, alice, 0), 99e18);
    }

    // ---- negative ----

    function test_bet_revertsMarketNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 0));
        market.placeBet(0, 0, 100 * USDC);
    }

    function test_bet_revertsAfterClose() public {
        uint256 id = _createBinary();
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketClosed.selector, id));
        market.placeBet(id, 0, 100 * USDC);
    }

    function test_bet_revertsOnResolvedMarket() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarketNotTrading.selector, id));
        market.placeBet(id, 0, 100 * USDC);
    }

    function test_bet_revertsInvalidOutcome() public {
        uint256 id = _createBinary();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 2, 2));
        market.placeBet(id, 2, 100 * USDC);
    }

    function test_bet_revertsAmountZero() public {
        uint256 id = _createBinary();
        vm.prank(alice);
        vm.expectRevert(AmountZero.selector);
        market.placeBet(id, 0, 0);
    }

    function test_bet_revertsBelowMin() public {
        uint256 id = _create(2, 0, 50 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmountBelowMin.selector, 40 * USDC, 50 * USDC));
        market.placeBet(id, 0, 40 * USDC);
    }

    function test_bet_revertsBelowMinDueToTransferFee() public {
        // minBet 100, but 1% fee means only 99 arrives -> reverts.
        MockFeeOnTransferERC20 fee = new MockFeeOnTransferERC20(100);
        fee.mint(alice, 1000e18);
        vm.prank(alice);
        fee.approve(address(market), type(uint256).max);
        uint256 id = market.createMarket(
            ParimutuelMarket.CreateParams(address(fee), address(resolver), closeTime, 2, 0, 100e18, "", "")
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmountBelowMin.selector, 99e18, 100e18));
        market.placeBet(id, 0, 100e18);
    }

    function test_bet_revertsWhenPaused() public {
        uint256 id = _createBinary();
        market.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.placeBet(id, 0, 100 * USDC);
    }

    function test_pause_thenUnpauseAllowsBet() public {
        uint256 id = _createBinary();
        market.pause();
        market.unpause();
        _bet(alice, id, 0, 100 * USDC);
        assertEq(market.stakeOf(id, alice, 0), 100 * USDC);
    }

    // ======================================================================
    // resolve / claim
    // ======================================================================

    function test_resolve_setsStateAndAccruesFee() public {
        uint256 id = _create(2, 200, 0); // 2% fee
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 300 * USDC);
        vm.warp(closeTime);

        vm.expectEmit(true, false, false, true, address(market));
        emit ParimutuelMarket.MarketResolved(id, 0, 392 * USDC, 8 * USDC);
        resolver.resolveMarket(address(market), id, 0);

        ParimutuelMarket.MarketView memory v = market.getMarket(id);
        assertEq(uint8(v.status), uint8(MarketTypes.Status.Resolved));
        assertEq(v.winningOutcomeId, 0);
        assertEq(v.netPot, 392 * USDC);
        assertEq(v.feeCollected, 8 * USDC);
        assertEq(market.accruedFees(address(usdc)), 8 * USDC);
    }

    function test_claim_soleWinnerGetsWholePotMinusFee() public {
        uint256 id = _create(2, 200, 0);
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 300 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.claim(id);
        assertEq(payout, 392 * USDC);
        assertEq(usdc.balanceOf(alice) - balBefore, 392 * USDC);
        assertTrue(market.isClaimed(id, alice));
    }

    function test_claim_twoWinnersSplitProRata() public {
        uint256 id = _create(2, 0, 0); // no fee
        _bet(alice, id, 0, 30 * USDC);
        _bet(carol, id, 0, 70 * USDC);
        _bet(bob, id, 1, 300 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        vm.prank(alice);
        assertEq(market.claim(id), 120 * USDC); // 30/100 * 400
        vm.prank(carol);
        assertEq(market.claim(id), 280 * USDC); // 70/100 * 400
    }

    function test_claim_multiOutcomeWinner() public {
        uint256 id = _create(3, 0, 0);
        _bet(alice, id, 2, 100 * USDC);
        _bet(bob, id, 0, 100 * USDC);
        _bet(carol, id, 1, 200 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 2);
        vm.prank(alice);
        assertEq(market.claim(id), 400 * USDC); // sole winner takes whole pot
    }

    function test_claimable_viewMatchesClaim() public {
        uint256 id = _create(2, 0, 0);
        _bet(alice, id, 0, 30 * USDC);
        _bet(carol, id, 0, 70 * USDC);
        _bet(bob, id, 1, 300 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        assertEq(market.claimable(id, alice), 120 * USDC);
        assertEq(market.claimable(id, bob), 0); // loser
    }

    // ---- negative claim/resolve ----

    function test_resolve_revertsNonResolver() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.warp(closeTime);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, stranger));
        market.resolve(id, 0);
    }

    function test_resolve_revertsBeforeClose() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.expectRevert(abi.encodeWithSelector(MarketNotClosed.selector, id));
        resolver.resolveMarket(address(market), id, 0);
    }

    function test_resolve_revertsInvalidOutcome() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.warp(closeTime);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 5, 2));
        resolver.resolveMarket(address(market), id, 5);
    }

    function test_resolve_revertsIfAlreadyResolved() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.expectRevert(abi.encodeWithSelector(MarketNotTrading.selector, id));
        resolver.resolveMarket(address(market), id, 0);
    }

    function test_claim_revertsIfNotResolved() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketNotResolved.selector, id));
        market.claim(id);
    }

    function test_claim_revertsForLoser() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.prank(bob);
        vm.expectRevert(NothingToClaim.selector);
        market.claim(id);
    }

    function test_claim_revertsOnDoubleClaim() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.prank(alice);
        market.claim(id);
        vm.prank(alice);
        vm.expectRevert(AlreadyClaimed.selector);
        market.claim(id);
    }

    // ======================================================================
    // invalidate / refund
    // ======================================================================

    function test_invalidate_enablesFullRefund() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 250 * USDC);

        resolver.invalidateMarket(address(market), id);
        assertEq(uint8(market.getMarket(id).status), uint8(MarketTypes.Status.Invalid));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        assertEq(market.refund(id), 100 * USDC);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 100 * USDC);

        vm.prank(bob);
        assertEq(market.refund(id), 250 * USDC);
    }

    function test_refund_sumsMultipleOutcomeStakes() public {
        uint256 id = _create(3, 0, 0);
        _bet(alice, id, 0, 40 * USDC);
        _bet(alice, id, 2, 60 * USDC);
        resolver.invalidateMarket(address(market), id);
        vm.prank(alice);
        assertEq(market.refund(id), 100 * USDC); // both stakes refunded at once
    }

    function test_resolve_autoInvalidatesWhenWinningPoolEmpty() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC); // nobody bets outcome 1
        vm.warp(closeTime);

        vm.expectEmit(true, false, false, true, address(market));
        emit ParimutuelMarket.MarketInvalidated(id, ParimutuelMarket.InvalidReason.NoWinners);
        resolver.resolveMarket(address(market), id, 1); // outcome 1 has zero stake

        assertEq(uint8(market.getMarket(id).status), uint8(MarketTypes.Status.Invalid));
        vm.prank(alice);
        assertEq(market.refund(id), 100 * USDC); // alice made whole
    }

    // ---- negative ----

    function test_invalidate_revertsNonResolver() public {
        uint256 id = _createBinary();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, stranger));
        market.invalidate(id);
    }

    function test_invalidate_revertsIfResolved() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.expectRevert(abi.encodeWithSelector(MarketNotTrading.selector, id));
        resolver.invalidateMarket(address(market), id);
    }

    function test_refund_revertsIfNotInvalid() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketNotInvalid.selector, id));
        market.refund(id);
    }

    function test_refund_revertsForNonBettor() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        resolver.invalidateMarket(address(market), id);
        vm.prank(stranger);
        vm.expectRevert(NothingToClaim.selector);
        market.refund(id);
    }

    function test_refund_revertsOnDoubleRefund() public {
        uint256 id = _createBinary();
        _bet(alice, id, 0, 100 * USDC);
        resolver.invalidateMarket(address(market), id);
        vm.prank(alice);
        market.refund(id);
        vm.prank(alice);
        vm.expectRevert(AlreadyClaimed.selector);
        market.refund(id);
    }

    // ======================================================================
    // fees
    // ======================================================================

    function test_withdrawFees_transfersAccrued() public {
        uint256 id = _create(2, 500, 0); // 5%
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        assertEq(market.accruedFees(address(usdc)), 10 * USDC); // 5% of 200

        market.withdrawFees(address(usdc), feeTo, 10 * USDC);
        assertEq(usdc.balanceOf(feeTo), 10 * USDC);
        assertEq(market.accruedFees(address(usdc)), 0);
    }

    function test_withdrawFees_revertsForNonManager() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.FEE_MANAGER_ROLE
            )
        );
        market.withdrawFees(address(usdc), feeTo, 1);
    }

    function test_withdrawFees_revertsAboveAccrued() public {
        vm.expectRevert(abi.encodeWithSelector(AmountBelowMin.selector, 1, 1));
        market.withdrawFees(address(usdc), feeTo, 1); // nothing accrued
    }

    // ======================================================================
    // prices / odds views (public market data)
    // ======================================================================

    function test_prices_reflectPools() public {
        uint256 id = _create(2, 0, 0);
        _bet(alice, id, 0, 60 * USDC);
        _bet(bob, id, 1, 40 * USDC);
        uint256[] memory p = market.getPrices(id);
        assertEq(p[0], 0.6e18);
        assertEq(p[1], 0.4e18);
        assertEq(market.priceWad(id, 0), 0.6e18);
    }

    function test_odds_reflectPot() public {
        uint256 id = _create(2, 0, 0);
        _bet(alice, id, 0, 100 * USDC);
        _bet(bob, id, 1, 100 * USDC);
        // pot 200, outcome0 pool 100 -> 2x
        assertEq(market.oddsWad(id, 0), 2e18);
    }

    function test_prices_emptyMarketIsZero() public {
        uint256 id = _createBinary();
        uint256[] memory p = market.getPrices(id);
        assertEq(p[0], 0);
        assertEq(p[1], 0);
    }

    // ======================================================================
    // conservation invariant (fuzz)
    // ======================================================================

    /// @dev After resolution, total outflow (winner payouts + fee) never exceeds the pot.
    function testFuzz_potIsConserved(uint96 a0, uint96 a1, uint16 feeBps) public {
        vm.assume(a0 > 0 && a1 > 0);
        feeBps = uint16(bound(feeBps, 0, uint16(Constants.MAX_FEE_BPS)));
        uint256 id = _create(2, feeBps, 0);

        usdc.mint(alice, a0);
        usdc.mint(bob, a1);
        _bet(alice, id, 0, a0);
        _bet(bob, id, 1, a1);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        uint256 potBalanceBefore = usdc.balanceOf(address(market));
        vm.prank(alice);
        uint256 payout = market.claim(id);
        uint256 fee = market.accruedFees(address(usdc));

        // Winner payout + protocol fee never exceeds the collateral held.
        assertLe(payout + fee, potBalanceBefore);
        // Remaining balance (dust + fee) is non-negative and small.
        assertGe(usdc.balanceOf(address(market)), fee);
    }
}

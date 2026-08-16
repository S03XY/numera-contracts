// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MarketTypes} from "../../src/libraries/MarketTypes.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Roles} from "../../src/access/Roles.sol";
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
    InvalidOutcome,
    AmountZero,
    AmountBelowMin,
    NothingToClaim,
    AlreadyClaimed,
    NotResolver,
    NotAuthorized,
    SlippageExceeded,
    InsufficientShares,
    ZeroLiquidity
} from "../../src/libraries/Errors.sol";

/// @notice End-to-end tests for the LMSR engine: create/seed, price-shifting buys & sells,
///         resolution, redemption, invalidation, fees, slippage, and every negative path.
contract LMSRMarketTest is Test {
    LMSRMarket market;
    TrustedResolver resolver;
    MockERC20 usdc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");
    address feeTo = makeAddr("feeTo");

    uint64 closeTime;
    uint256 constant USDC = 1e6;
    uint256 constant B = 1000 * USDC; // liquidity parameter

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new LMSRMarket(address(this)); // this contract is admin + LP for created markets
        resolver = new TrustedResolver(address(this));
        closeTime = uint64(block.timestamp + 1 days);

        // Fund the LP (this contract) so it can seed subsidies.
        usdc.mint(address(this), 100_000_000 * USDC);
        usdc.approve(address(market), type(uint256).max);

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address who) internal {
        usdc.mint(who, 10_000_000 * USDC);
        vm.prank(who);
        usdc.approve(address(market), type(uint256).max);
    }

    function _create(uint32 outcomes, uint16 feeBps, uint256 b) internal returns (uint256 id) {
        id = market.createMarket(
            LMSRMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver),
                closeTime: closeTime,
                outcomeCount: outcomes,
                feeBps: feeBps,
                b: b,
                category: bytes32("SPORTS"),
                metadataHash: keccak256("Will Team A win?")
            })
        );
    }

    function _createBinary() internal returns (uint256) {
        return _create(2, 0, B);
    }

    function _buy(address who, uint256 id, uint256 outcome, uint256 shares) internal returns (uint256 paid) {
        vm.prank(who);
        paid = market.buy(id, outcome, shares, type(uint256).max);
    }

    // ======================================================================
    // create & seeding
    // ======================================================================

    function test_create_seedsSubsidyAndConfig() public {
        uint256 lpBalBefore = usdc.balanceOf(address(this));
        uint256 id = _create(2, 100, B);
        LMSRMarket.MarketView memory v = market.getMarket(id);

        assertEq(v.b, B);
        assertEq(v.feeBps, 100);
        assertEq(v.lp, address(this));
        assertEq(uint8(v.status), uint8(MarketTypes.Status.Trading));
        assertTrue(v.tradingOpen);
        // subsidy = b*ln(2) ≈ 693.147181 USDC pulled from the LP into the pot
        assertApproxEqAbs(v.pot, 693_147_181, 3);
        assertEq(lpBalBefore - usdc.balanceOf(address(this)), v.pot);
    }

    function test_create_pricesStartUniform() public {
        uint256 id = _create(4, 0, B);
        uint256[] memory p = market.prices(id);
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(p[i], 0.25e18, 1e6);
        }
    }

    // ---- negative ----

    function test_create_revertsZeroB() public {
        vm.expectRevert(ZeroLiquidity.selector);
        market.createMarket(
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, 0, "", "")
        );
    }

    function test_create_revertsTooManyOutcomes() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcomeCount.selector, 65, 2, 64));
        market.createMarket(
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 65, 0, B, "", "")
        );
    }

    function test_create_revertsFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1001, 1000));
        market.createMarket(
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 1001, B, "", "")
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
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, B, "", "")
        );
    }

    // ======================================================================
    // buy: the public price shift
    // ======================================================================

    function test_buy_shiftsPriceUpForBoughtOutcome() public {
        uint256 id = _createBinary();
        uint256 yesBefore = market.priceWad(id, 1);
        uint256 noBefore = market.priceWad(id, 0);
        assertApproxEqAbs(yesBefore, 0.5e18, 1e9);

        _buy(alice, id, 1, 300 * USDC); // buy "Yes"

        uint256 yesAfter = market.priceWad(id, 1);
        uint256 noAfter = market.priceWad(id, 0);
        assertGt(yesAfter, yesBefore); // Yes price rose
        assertLt(noAfter, noBefore); // No price fell
        assertApproxEqAbs(yesAfter + noAfter, Constants.WAD, 3); // still sums to 1
    }

    function test_buy_updatesLedgersAndPot() public {
        uint256 id = _createBinary();
        uint256 potBefore = market.getMarket(id).pot;
        uint256 paid = _buy(alice, id, 1, 200 * USDC);

        assertEq(market.sharesOf(id, alice, 1), 200 * USDC);
        assertEq(market.outcomeShares(id, 1), 200 * USDC);
        assertEq(market.getMarket(id).pot, potBefore + paid); // no fee -> pot grows by cost
    }

    function test_buy_quoteMatchesExecution() public {
        uint256 id = _create(2, 50, B); // 0.5% fee
        (,, uint256 totalCost) = market.quoteBuy(id, 1, 250 * USDC);
        uint256 paid = _buy(alice, id, 1, 250 * USDC);
        assertEq(paid, totalCost);
    }

    function test_buy_accruesFee() public {
        uint256 id = _create(2, 100, B); // 1%
        (uint256 baseCost,,) = market.quoteBuy(id, 1, 300 * USDC);
        _buy(alice, id, 1, 300 * USDC);
        assertEq(market.accruedFees(address(usdc)), baseCost / 100);
    }

    function test_buy_priceMovesTowardHeavilyBoughtSide() public {
        uint256 id = _createBinary();
        _buy(alice, id, 1, 2000 * USDC); // large Yes buy (2x liquidity)
        assertGt(market.priceWad(id, 1), 0.8e18); // Yes now dominant
    }

    // ---- negative ----

    function test_buy_revertsSlippage() public {
        uint256 id = _createBinary();
        (,, uint256 totalCost) = market.quoteBuy(id, 1, 200 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, totalCost, totalCost - 1));
        market.buy(id, 1, 200 * USDC, totalCost - 1);
    }

    function test_buy_revertsAfterClose() public {
        uint256 id = _createBinary();
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketClosed.selector, id));
        market.buy(id, 1, 100 * USDC, type(uint256).max);
    }

    function test_buy_revertsInvalidOutcome() public {
        uint256 id = _createBinary();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 2, 2));
        market.buy(id, 2, 100 * USDC, type(uint256).max);
    }

    function test_buy_revertsZeroShares() public {
        uint256 id = _createBinary();
        vm.prank(alice);
        vm.expectRevert(AmountZero.selector);
        market.buy(id, 1, 0, type(uint256).max);
    }

    function test_buy_revertsWhenPaused() public {
        uint256 id = _createBinary();
        market.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.buy(id, 1, 100 * USDC, type(uint256).max);
    }

    // ======================================================================
    // sell
    // ======================================================================

    function test_sell_refundsAndLowersPrice() public {
        uint256 id = _createBinary();
        _buy(alice, id, 1, 400 * USDC);
        uint256 priceAfterBuy = market.priceWad(id, 1);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 refund = market.sell(id, 1, 200 * USDC, 0);

        assertGt(refund, 0);
        assertEq(usdc.balanceOf(alice) - balBefore, refund);
        assertEq(market.sharesOf(id, alice, 1), 200 * USDC); // half sold
        assertLt(market.priceWad(id, 1), priceAfterBuy); // price fell back
    }

    function test_sell_quoteMatchesExecution() public {
        uint256 id = _createBinary();
        _buy(alice, id, 1, 400 * USDC);
        (,, uint256 netRefund) = market.quoteSell(id, 1, 150 * USDC);
        vm.prank(alice);
        uint256 refund = market.sell(id, 1, 150 * USDC, 0);
        assertEq(refund, netRefund);
    }

    function test_sell_roundTripNoFreeMoney() public {
        uint256 id = _createBinary();
        uint256 paid = _buy(alice, id, 1, 300 * USDC);
        vm.prank(alice);
        uint256 refund = market.sell(id, 1, 300 * USDC, 0);
        assertLe(refund, paid); // selling everything back never yields a profit
    }

    function test_sell_revertsInsufficientShares() public {
        uint256 id = _createBinary();
        _buy(alice, id, 1, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientShares.selector, 100 * USDC, 150 * USDC));
        market.sell(id, 1, 150 * USDC, 0);
    }

    function test_sell_revertsSlippage() public {
        uint256 id = _createBinary();
        _buy(alice, id, 1, 300 * USDC);
        (,, uint256 netRefund) = market.quoteSell(id, 1, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, netRefund, netRefund + 1));
        market.sell(id, 1, 100 * USDC, netRefund + 1);
    }

    // ======================================================================
    // resolve / redeem / liquidity  (+ conservation)
    // ======================================================================

    function test_resolve_setsLpPayout() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 300 * USDC);
        _buy(bob, id, 1, 100 * USDC);
        uint256 pot = market.getMarket(id).pot;
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        LMSRMarket.MarketView memory v = market.getMarket(id);
        assertEq(uint8(v.status), uint8(MarketTypes.Status.Resolved));
        assertEq(v.winningOutcomeId, 0);
        assertEq(v.lpPayout, pot - 300 * USDC); // pot minus winning shares
    }

    function test_redeem_winnerGets1to1() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 300 * USDC);
        _buy(bob, id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 got = market.redeem(id);
        assertEq(got, 300 * USDC); // 300 winning shares -> 300 USDC
        assertEq(usdc.balanceOf(alice) - balBefore, 300 * USDC);
    }

    function test_fullConservation_resolvedMarket() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 300 * USDC);
        _buy(bob, id, 1, 100 * USDC);
        _buy(carol, id, 0, 50 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        uint256 pot = market.getMarket(id).pot;

        vm.prank(alice);
        uint256 aliceGot = market.redeem(id);
        vm.prank(carol);
        uint256 carolGot = market.redeem(id);
        uint256 lpGot = market.redeemLiquidity(id); // LP == this contract

        // Winners (350 shares total) + LP settlement == entire pot. Nothing stranded, nothing minted.
        assertEq(aliceGot, 300 * USDC);
        assertEq(carolGot, 50 * USDC);
        assertEq(aliceGot + carolGot + lpGot, pot);
    }

    function test_redeem_revertsForLoser() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 100 * USDC);
        _buy(bob, id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.prank(bob);
        vm.expectRevert(NothingToClaim.selector);
        market.redeem(id);
    }

    function test_redeem_revertsDoubleRedeem() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 100 * USDC);
        _buy(bob, id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.prank(alice);
        market.redeem(id);
        vm.prank(alice);
        vm.expectRevert(AlreadyClaimed.selector);
        market.redeem(id);
    }

    function test_redeemLiquidity_revertsForNonLp() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        market.redeemLiquidity(id);
    }

    function test_resolve_revertsBeforeClose() public {
        uint256 id = _createBinary();
        _buy(alice, id, 0, 100 * USDC);
        vm.expectRevert(abi.encodeWithSelector(MarketNotClosed.selector, id));
        resolver.resolveMarket(address(market), id, 0);
    }

    function test_resolve_revertsNonResolver() public {
        uint256 id = _createBinary();
        vm.warp(closeTime);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, stranger));
        market.resolve(id, 0);
    }

    // ======================================================================
    // invalidate  (+ conservation)
    // ======================================================================

    function test_invalidate_refundsCostBasis_andConserves() public {
        uint256 id = _createBinary();
        uint256 subsidy = market.getMarket(id).pot;
        uint256 aliceCost = _buy(alice, id, 0, 200 * USDC);
        uint256 bobCost = _buy(bob, id, 1, 100 * USDC);

        resolver.invalidateMarket(address(market), id);
        uint256 pot = market.getMarket(id).pot;
        assertEq(pot, subsidy + aliceCost + bobCost);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceGot = market.redeem(id);
        vm.prank(bob);
        uint256 bobGot = market.redeem(id);
        uint256 lpGot = market.redeemLiquidity(id);

        assertEq(aliceGot, aliceCost); // exact money back
        assertEq(bobGot, bobCost);
        assertEq(usdc.balanceOf(alice) - aliceBefore, aliceCost);
        assertEq(lpGot, subsidy); // LP recovers exactly the seeded subsidy
        assertEq(aliceGot + bobGot + lpGot, pot); // conserved
    }

    function test_invalidate_afterProfitTaking_lpAbsorbsButStaysSolvent() public {
        // A trader who bought then sold at a profit leaves with cash; on invalidation the LP's
        // residual shrinks (bounded loss), but the contract never becomes insolvent.
        uint256 id = _createBinary();
        _buy(alice, id, 0, 1000 * USDC); // alice pushes price 0 up
        // bob buys 0 even higher then... alice sells back at a higher price = profit
        _buy(bob, id, 0, 1000 * USDC);
        vm.prank(alice);
        market.sell(id, 0, 1000 * USDC, 0); // alice exits at a profit

        resolver.invalidateMarket(address(market), id);
        uint256 pot = market.getMarket(id).pot;

        // Everyone with positive net contribution can still redeem; totals never exceed the pot.
        uint256 paidOut;
        vm.prank(bob);
        paidOut += market.redeem(id);
        // alice's net contribution is <= 0 (she profited) -> nothing to redeem
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        market.redeem(id);
        uint256 lpGot = market.redeemLiquidity(id);
        paidOut += lpGot;

        assertLe(paidOut, pot); // solvent: never pays out more than it holds
    }

    // ======================================================================
    // fees & multi-outcome
    // ======================================================================

    function test_withdrawFees() public {
        uint256 id = _create(2, 200, B); // 2%
        _buy(alice, id, 1, 500 * USDC);
        uint256 accrued = market.accruedFees(address(usdc));
        assertGt(accrued, 0);
        market.withdrawFees(address(usdc), feeTo, accrued);
        assertEq(usdc.balanceOf(feeTo), accrued);
    }

    function test_multiOutcome_tradeAndResolve() public {
        uint256 id = _create(3, 0, B);
        _buy(alice, id, 2, 300 * USDC);
        _buy(bob, id, 0, 100 * USDC);
        // outcome 2 most bought -> highest price
        uint256[] memory p = market.prices(id);
        assertGt(p[2], p[0]);
        assertGt(p[0], p[1]);

        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 2);
        vm.prank(alice);
        assertEq(market.redeem(id), 300 * USDC);
    }

    // ======================================================================
    // fuzz: pot always covers winner shares (solvency)
    // ======================================================================

    function testFuzz_potCoversWinningShares(uint96 s0, uint96 s1) public {
        uint256 id = _createBinary();
        uint256 buy0 = bound(uint256(s0), 1 * USDC, 100_000 * USDC);
        uint256 buy1 = bound(uint256(s1), 1 * USDC, 100_000 * USDC);
        _buy(alice, id, 0, buy0);
        _buy(bob, id, 1, buy1);
        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0);

        LMSRMarket.MarketView memory v = market.getMarket(id);
        // pot must cover the winning shares fully, with a non-negative LP remainder.
        assertGe(v.pot, buy0);
        assertEq(v.lpPayout, v.pot - buy0);
    }
}

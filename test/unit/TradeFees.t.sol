// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../../src/markets/LsLmsrMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Roles} from "../../src/access/Roles.sol";
import {AmountBelowMin} from "../../src/libraries/Errors.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title TradeFeesTest
/// @notice The single all-in trading fee, and the minimum that makes sponsored gas safe to give away.
///
/// @dev Two things are being protected here, and only one of them is revenue.
///
///      The fee is Numera's whole take — there is no separate gas charge, because a visible gas line
///      item would have to be quoted in MON and would make the product feel like infrastructure
///      rather than a bet.
///
///      The minimum is a security parameter. Trades are relayed at our expense by a forwarder that
///      cannot be authenticated (authentication would rebuild the user↔account link the design
///      exists to break), so nothing distinguishes an attacker's trade from an honest one. What
///      bounds the attack is arithmetic: if the smallest legal trade's fee exceeds the gas of
///      relaying it, spam costs the attacker more than it costs us.
///
///      And underneath both: fees must never be counted as market collateral. `collateralHeld` backs
///      winners and void refunds; money earmarked for withdrawal cannot be part of that.
contract TradeFeesTest is Test {
    LsLmsrMarket internal engine;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal fees = address(0xFEE5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;
    uint16 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant MIN_TRADE = 5 * UNIT;

    uint256 internal binary;
    uint64 internal closeTime;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.startPrank(admin);
        engine = new LsLmsrMarket(admin, fees, address(0), address(0));
        engine.setTradeFee(FEE_BPS);
        engine.setMinTradeCost(address(usdc), MIN_TRADE);
        vm.stopPrank();

        closeTime = uint64(block.timestamp + 7 days);
        _fund(admin, 1_000_000 * UNIT);
        _fund(alice, 1_000_000 * UNIT);
        _fund(bob, 1_000_000 * UNIT);

        vm.prank(admin);
        binary = engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 2,
                alpha: 0.025e18,
                sStar: 2000e18,
                seedPerOutcome: SEED,
                category: bytes32("SPORTS"),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(engine), type(uint256).max);
    }

    function _maxQ(uint256 id) internal view returns (uint256 m) {
        uint32 n = engine.outcomeCountOf(id);
        for (uint256 i; i < n; ++i) {
            uint256 v = engine.outcomeShares(id, i);
            if (v > m) m = v;
        }
    }

    function _assertSolvent(uint256 id) internal view {
        assertGe(engine.collateralOf(id), _maxQ(id), "INSOLVENT: collateral < max(q)");
    }

    /// @dev Every unit the contract holds is either backing a market or waiting to be swept. If this
    ///      drifts, one of the two is being double-counted.
    function _assertBooksBalance() internal view {
        assertEq(
            usdc.balanceOf(address(engine)),
            engine.collateralOf(binary) + engine.feesAccrued(address(usdc)),
            "token balance != collateral + accrued fees"
        );
    }

    // ================================================================== charging

    function test_buyChargesAFeeAndTheQuoteAlreadyIncludesIt() public {
        // The quote is what the UI shows. If it excluded the fee, every price on every screen would
        // be wrong by the fee, and a `maxCost` derived from it would revert at the last moment.
        uint256 quoted = engine.quoteBuy(binary, 0, 20 * UNIT);
        uint256 collateralBefore = engine.collateralOf(binary);
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 charged = engine.buy(binary, 0, 20 * UNIT, type(uint256).max);

        assertEq(charged, quoted, "the quote did not match what the trader was charged");
        assertEq(before - usdc.balanceOf(alice), charged, "trader paid something other than `charged`");

        uint256 cost = engine.collateralOf(binary) - collateralBefore;
        uint256 fee = engine.feesAccrued(address(usdc));
        assertEq(cost + fee, charged, "charge is not cost + fee");
        assertEq(fee, (cost * FEE_BPS + 9_999) / 10_000, "fee is not 1% of cost, rounded up");
        _assertBooksBalance();
    }

    function test_feeIsNotCountedAsMarketCollateral() public {
        // The invariant everything else rests on. A fee inside `collateralHeld` would let a sweep
        // take money that was backing a winner.
        uint256 collateralBefore = engine.collateralOf(binary);

        vm.prank(alice);
        uint256 charged = engine.buy(binary, 0, 20 * UNIT, type(uint256).max);

        uint256 cost = engine.collateralOf(binary) - collateralBefore;
        assertLt(cost, charged, "the whole charge became collateral, so the fee was double-counted");
        assertEq(charged - cost, engine.feesAccrued(address(usdc)), "the difference is not the fee");
        _assertSolvent(binary);
        _assertBooksBalance();
    }

    function test_sellTakesTheFeeFromProceeds() public {
        vm.prank(alice);
        engine.buy(binary, 0, 40 * UNIT, type(uint256).max);

        uint256 accruedAfterBuy = engine.feesAccrued(address(usdc));
        uint256 quoted = engine.quoteSell(binary, 0, 20 * UNIT);
        uint256 collateralBefore = engine.collateralOf(binary);
        uint256 before = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 received = engine.sell(binary, 0, 20 * UNIT, 0);

        assertEq(received, quoted, "the quote did not match what the trader received");
        assertEq(usdc.balanceOf(alice) - before, received, "trader received something other than `received`");

        uint256 gross = collateralBefore - engine.collateralOf(binary);
        uint256 fee = engine.feesAccrued(address(usdc)) - accruedAfterBuy;
        assertEq(gross - fee, received, "trader did not receive gross minus fee");
        assertEq(fee, (gross * FEE_BPS + 9_999) / 10_000, "sell fee is not 1% of gross");
        _assertSolvent(binary);
        _assertBooksBalance();
    }

    function test_settlementTakesNoFurtherFee() public {
        // A winner has already paid on the way in. Charging again at redemption would be a second
        // bite of the same trade, and it is the fee traders would notice most.
        vm.prank(alice);
        engine.buy(binary, 0, 20 * UNIT, type(uint256).max);

        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.resolve(binary, 0);

        uint256 accrued = engine.feesAccrued(address(usdc));
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.redeem(binary);

        assertEq(usdc.balanceOf(alice) - before, 20 * UNIT, "winning shares did not pay 1:1");
        assertEq(engine.feesAccrued(address(usdc)), accrued, "redemption charged a fee");
    }

    function test_aZeroFeeChargesNothing() public {
        vm.prank(admin);
        engine.setTradeFee(0);

        uint256 quoted = engine.quoteBuy(binary, 0, 20 * UNIT);
        vm.prank(alice);
        uint256 charged = engine.buy(binary, 0, 20 * UNIT, type(uint256).max);

        assertEq(charged, quoted, "a zero fee still moved the price");
        assertEq(engine.feesAccrued(address(usdc)), 0, "a zero fee accrued something");
    }

    function test_theQuoteIsExactlyEnoughToCoverTheTrade() public {
        // The tightest statement of quote correctness, and it holds **within one block**: a trader
        // who authorises exactly the quoted amount succeeds, and one unit less fails.
        //
        // Across blocks it does not hold, and must not be read as saying otherwise — the spread
        // carries a time term (see {_spreadFrom}) that widens as a market approaches close, so a
        // quote fetched now is stale by the time a transaction lands. Callers apply a slippage
        // tolerance; see `test_theQuoteWidensAsTheMarketApproachesClose` for the mechanism.
        uint256 quoted = engine.quoteBuy(binary, 0, 20 * UNIT);

        vm.prank(alice);
        vm.expectRevert();
        engine.buy(binary, 0, 20 * UNIT, quoted - 1);

        vm.prank(alice);
        engine.buy(binary, 0, 20 * UNIT, quoted);
        assertEq(engine.sharesOf(binary, alice, 0), 20 * UNIT);
    }

    function test_theQuoteWidensAsTheMarketApproachesClose() public {
        // Pins the time-dependence deliberately, because it is the reason every caller needs a
        // slippage tolerance. Discovered the hard way on testnet: a relayed buy whose `maxCost` was
        // the quote reverted by two base units, purely because simulation and execution sat in
        // different blocks.
        uint256 early = engine.quoteBuy(binary, 0, 20 * UNIT);

        vm.warp(closeTime - 1 hours);
        uint256 late = engine.quoteBuy(binary, 0, 20 * UNIT);

        assertGt(late, early, "the spread's time term is not being applied");
    }

    // =================================================================== the minimum

    function test_buyBelowTheMinimumIsRefused() public {
        // ~1 USDC of cost, well under the 5 USDC floor.
        uint256 quoted = engine.quoteBuy(binary, 0, 2 * UNIT);
        assertLt(quoted, MIN_TRADE, "this case no longer sits below the floor");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmountBelowMin.selector, quoted, MIN_TRADE));
        engine.buy(binary, 0, 2 * UNIT, type(uint256).max);
    }

    function test_aPartialSaleBelowTheFloorIsRefused() public {
        vm.prank(alice);
        engine.buy(binary, 0, 40 * UNIT, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        engine.sell(binary, 0, 2 * UNIT, 0);
    }

    function test_aCompleteExitIsAlwaysAllowedHoweverSmall() public {
        // Without this exemption the floor becomes a trap: a position worth less than the minimum
        // could never be closed, only abandoned until settlement.
        vm.prank(alice);
        engine.buy(binary, 0, 40 * UNIT, type(uint256).max);
        vm.prank(alice);
        engine.sell(binary, 0, 38 * UNIT, 0);

        uint256 remaining = engine.sharesOf(binary, alice, 0);
        assertEq(remaining, 2 * UNIT, "setup did not leave a sub-minimum position");

        vm.prank(alice);
        uint256 received = engine.sell(binary, 0, remaining, 0);

        assertLt(received, MIN_TRADE, "this case no longer exercises the exemption");
        assertEq(engine.sharesOf(binary, alice, 0), 0, "a complete exit was refused");
        _assertSolvent(binary);
    }

    function test_anUnsetMinimumBlocksNothing() public {
        vm.prank(admin);
        engine.setMinTradeCost(address(usdc), 0);

        vm.prank(alice);
        engine.buy(binary, 0, 2 * UNIT, type(uint256).max);
        assertEq(engine.sharesOf(binary, alice, 0), 2 * UNIT);
    }

    // ==================================================================== solvency

    function test_voidedMarketStillRefundsEveryoneAfterManyFeeCharges() public {
        // The subtle one. `netContributed` moves by the trade's *cost*, not by what the trader paid,
        // because `sumPositiveNet` must stay backed by `collateralHeld`. If a fee were counted as
        // contribution, a voided market would owe refunds it was never paid and `invalidate` would
        // revert as insolvent — with traders' money locked inside it.
        // The floor is not what is under test here, and a skewing book eventually pushes a fixed-size
        // partial sale under it. Removed so this exercises the accounting across many fee charges.
        vm.prank(admin);
        engine.setMinTradeCost(address(usdc), 0);

        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            engine.buy(binary, 0, 30 * UNIT, type(uint256).max);
            vm.prank(bob);
            engine.buy(binary, 1, 25 * UNIT, type(uint256).max);
            vm.prank(alice);
            engine.sell(binary, 0, 10 * UNIT, 0);
        }

        uint256 accrued = engine.feesAccrued(address(usdc));
        assertGt(accrued, 0, "no fees were charged, so this proves nothing");

        // Reverts here — as `Insolvent` — if a fee ever entered `netContributed`.
        vm.prank(resolver);
        engine.invalidate(binary);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        engine.redeem(binary);
        vm.prank(bob);
        engine.redeem(binary);

        assertGt(usdc.balanceOf(alice) - aliceBefore, 0, "alice was refunded nothing");
        assertGt(usdc.balanceOf(bob) - bobBefore, 0, "bob was refunded nothing");

        // Refunds are cost basis, not fees: fees were earned on trades that did execute, and
        // solvency leaves no alternative. What matters is that paying both refunds did not eat into
        // the accrued fees, which are still there to be swept.
        assertGe(usdc.balanceOf(address(engine)), accrued, "refunds were paid out of accrued fees");

        vm.prank(admin);
        assertEq(engine.sweepFees(address(usdc)), accrued, "fees did not survive a full void settlement");
    }

    function test_solvencyHoldsAcrossAFeeChargingSession() public {
        for (uint256 i; i < 8; ++i) {
            vm.prank(alice);
            engine.buy(binary, 0, 30 * UNIT, type(uint256).max);
            _assertSolvent(binary);
            _assertBooksBalance();

            vm.prank(bob);
            engine.buyComplement(binary, 0, 20 * UNIT, type(uint256).max);
            _assertSolvent(binary);
            _assertBooksBalance();

            vm.prank(alice);
            engine.sell(binary, 0, 15 * UNIT, 0);
            _assertSolvent(binary);
            _assertBooksBalance();
        }
    }

    // ============================================================ quote/execution parity

    function test_theBuyQuoteEqualsTheChargeOnAnyBook(uint256 skewRaw, uint256 sizeRaw) public {
        // The regression that reached testnet. `quoteBuy` and `buy` were algebraically identical
        // and numerically were not: the public path recomputed `C(q)` through `costToBuy` and
        // `prices`, while the trade derived both from one cached `c0`. On a live book that came out
        // 13 base units apart — enough to revert every trade whose `maxCost` came from the quote,
        // which is every trade the UI places.
        //
        // Fuzzed over the skew because the divergence was state-dependent: it did not appear on a
        // fresh symmetric book, which is exactly what the earlier fixed-state test used.
        // Both bounded above the 5 USDC floor: this test is about quote parity, and a setup trade
        // rejected by the minimum would fail it for an unrelated reason.
        uint256 skew = bound(skewRaw, 20 * UNIT, 400 * UNIT);
        uint256 size = bound(sizeRaw, 20 * UNIT, 200 * UNIT);

        vm.prank(bob);
        engine.buy(binary, 0, skew, type(uint256).max);

        uint256 quoted = engine.quoteBuy(binary, 0, size);
        vm.prank(alice);
        uint256 charged = engine.buy(binary, 0, size, quoted);

        assertEq(charged, quoted, "the quote is not what the trade charged");
    }

    function test_theSellQuoteEqualsTheProceedsOnAnyBook(uint256 skewRaw, uint256 sizeRaw) public {
        // The floor is not under test here, and it has to come off *before* the setup trades: on a
        // skewed book, 20 shares of the cheap side cost well under 5 USDC, so the setup itself would
        // be rejected for a reason that has nothing to do with quote parity.
        vm.prank(admin);
        engine.setMinTradeCost(address(usdc), 0);

        uint256 skew = bound(skewRaw, 20 * UNIT, 400 * UNIT);
        uint256 size = bound(sizeRaw, 20 * UNIT, 200 * UNIT);

        vm.prank(alice);
        engine.buy(binary, 0, size + 200 * UNIT, type(uint256).max);
        vm.prank(bob);
        engine.buy(binary, 1, skew, type(uint256).max);

        uint256 quoted = engine.quoteSell(binary, 0, size);
        vm.prank(alice);
        uint256 received = engine.sell(binary, 0, size, quoted);

        assertEq(received, quoted, "the quote is not what the trade paid");
    }

    // ======================================================================= admin

    function test_theFeeCannotBeRaisedPastItsCeiling() public {
        uint16 max = engine.MAX_TRADE_FEE_BPS();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.FeeTooHigh.selector, max + 1, max));
        engine.setTradeFee(max + 1);

        vm.prank(admin);
        engine.setTradeFee(max);
        assertEq(engine.tradeFeeBps(), max);
    }

    function test_onlyTheFeeManagerCanChangeFeeSettings() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setTradeFee(0);

        vm.prank(alice);
        vm.expectRevert();
        engine.setMinTradeCost(address(usdc), 0);

        vm.prank(alice);
        vm.expectRevert();
        engine.sweepFees(address(usdc));
    }

    function test_sweepingMovesOnlyFeesAndNeverCollateral() public {
        vm.prank(alice);
        engine.buy(binary, 0, 40 * UNIT, type(uint256).max);

        uint256 accrued = engine.feesAccrued(address(usdc));
        uint256 collateral = engine.collateralOf(binary);
        assertGt(accrued, 0, "nothing accrued to sweep");

        vm.prank(admin);
        uint256 swept = engine.sweepFees(address(usdc));

        assertEq(swept, accrued, "swept a different amount than accrued");
        assertEq(usdc.balanceOf(fees), accrued, "fee recipient was not paid");
        assertEq(engine.feesAccrued(address(usdc)), 0, "accrual not cleared");
        assertEq(engine.collateralOf(binary), collateral, "a sweep touched market collateral");
        _assertSolvent(binary);
        _assertBooksBalance();
    }

    function test_sweepingTwiceTakesNothingTheSecondTime() public {
        vm.prank(alice);
        engine.buy(binary, 0, 40 * UNIT, type(uint256).max);

        vm.prank(admin);
        engine.sweepFees(address(usdc));

        vm.prank(admin);
        vm.expectRevert(LsLmsrMarket.NothingToSweep.selector);
        engine.sweepFees(address(usdc));
    }
}

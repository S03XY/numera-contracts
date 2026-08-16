// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../src/markets/LsLmsrMarket.sol";
import {LsLmsr} from "../src/libraries/LsLmsr.sol";
import {MarketTypes} from "../src/libraries/MarketTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {
    AlreadyClaimed,
    AmountZero,
    InsufficientShares,
    InvalidOutcome,
    InvalidOutcomeCount,
    MarketClosed,
    MarketNotClosed,
    MarketNotResolved,
    NothingToClaim,
    NotAuthorized,
    NotResolver,
    SlippageExceeded
} from "../src/libraries/Errors.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title LsLmsrMarketTest
/// @notice Positive, negative and regression coverage for the trading engine.
///
/// @dev The engine's whole promise is that a trader can go long, go short, and get out — and that
///      the pool can always pay. Each section below is one of those claims.
contract LsLmsrMarketTest is Test {
    LsLmsrMarket internal engine;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal fees = address(0xFEE5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    /// USDC-shaped: 6 decimals, so one share is 1e6 base units and redeems for exactly 1 USDC.
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;
    uint256 internal constant ALPHA = 0.025e18;
    uint256 internal constant S_STAR = 2000e18;
    uint64 internal closeTime;

    uint256 internal binary; // 2 outcomes
    uint256 internal triple; // 3 outcomes, for the middle-winner short case

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(admin);
        engine = new LsLmsrMarket(admin, fees, address(0), address(0));

        closeTime = uint64(block.timestamp + 7 days);

        _fund(admin, 1_000_000 * UNIT);
        _fund(alice, 1_000_000 * UNIT);
        _fund(bob, 1_000_000 * UNIT);

        binary = _create(2);
        triple = _create(3);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(engine), type(uint256).max);
    }

    function _create(uint32 n) internal returns (uint256 id) {
        // alpha per the brief: 0.025 binary, else 0.035/(n·ln n). Hardcoded rather than derived so
        // the test does not lean on the same maths it is checking.
        uint256 alpha = n == 2 ? ALPHA : (n == 3 ? 0.010619e18 : 0.006312e18);
        vm.prank(admin);
        id = engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: n,
                alpha: alpha,
                sStar: S_STAR,
                seedPerOutcome: SEED,
                category: bytes32("SPORTS"),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    function _maxQ(uint256 id) internal view returns (uint256 m) {
        uint32 n = engine.outcomeCountOf(id);
        for (uint256 i; i < n; ++i) {
            uint256 v = engine.outcomeShares(id, i);
            if (v > m) m = v;
        }
    }

    /// @dev The claim the product is sold on, checked after every single state change below.
    function _assertSolvent(uint256 id) internal view {
        assertGe(engine.collateralOf(id), _maxQ(id), "INSOLVENT: collateral < max(q)");
    }

    // ================================================================== creation

    function test_createSeedsTheBookAndChargesTheCreatorABoundedLoss() public {
        // The seed is the entire subsidy: C(q_seed) in, S back at resolution, so the loss is
        // b·ln(n) whatever happens. At S=1000/outcome on binary defaults that is 69.31.
        uint256 held = engine.collateralOf(binary);
        assertApproxEqAbs(held, 1069_314718, 1e4, "seed cost = S + b*ln(2)");

        assertEq(engine.outcomeShares(binary, 0), SEED);
        assertEq(engine.outcomeShares(binary, 1), SEED);

        uint256[] memory p = engine.prices(binary);
        assertApproxEqAbs(p[0], p[1], 1, "a fresh binary book is symmetric");
        assertGe(p[0] + p[1], 1e18, "sum(p) >= 1");
        _assertSolvent(binary);
    }

    function test_creatorHoldsNoSellableShares() public view {
        // "Locked until resolution" is structural, not a flag: the seed never enters the ledger, so
        // there is nothing for sell() to find.
        assertEq(engine.sharesOf(binary, admin, 0), 0, "seed must not be credited as shares");
    }

    // ================================================================== long

    function test_buyCreditsSharesAndMovesPriceTheRightWay() public {
        uint256[] memory before = engine.prices(binary);

        uint256 quoted = engine.quoteBuy(binary, 0, 100 * UNIT);
        vm.prank(alice);
        uint256 charged = engine.buy(binary, 0, 100 * UNIT, quoted);

        assertEq(charged, quoted, "quote must match what is charged");
        assertEq(engine.sharesOf(binary, alice, 0), 100 * UNIT);
        assertEq(engine.outcomeShares(binary, 0), SEED + 100 * UNIT);

        uint256[] memory afterP = engine.prices(binary);
        assertGt(afterP[0], before[0], "buying raises its own price");
        assertLt(afterP[1], before[1], "and lowers the other");
        _assertSolvent(binary);
    }

    function test_buyCostsMoreThanTheRawCurveBecauseOfTheSpread() public view {
        // phi is charged on top of C and never inside it, which is what keeps C path independent.
        uint256 quoted = engine.quoteBuy(binary, 0, 100 * UNIT);
        uint256 spread = engine.spreadWad(binary, 0);
        assertGt(spread, 0, "a spread must be charged");
        assertGt(quoted, 100 * UNIT / 2, "sanity: ~half a dollar per share at 50/50");
    }

    // ================================================================== short

    function test_shortOnBinaryIsExactlyBuyingTheOtherSide() public {
        // If these ever diverged, buyComplement would not be a clean short.
        uint256 viaShort = engine.quoteBuyComplement(binary, 0, 50 * UNIT);
        uint256 viaBuy = engine.quoteBuy(binary, 1, 50 * UNIT);
        assertEq(viaShort, viaBuy, "binary short == buying the other outcome");
    }

    function test_shortCreditsEveryOtherOutcome() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 40 * UNIT, type(uint256).max);

        assertEq(engine.sharesOf(triple, alice, 0), 0, "the shorted outcome is not bought");
        assertEq(engine.sharesOf(triple, alice, 1), 40 * UNIT);
        assertEq(engine.sharesOf(triple, alice, 2), 40 * UNIT);
        _assertSolvent(triple);
    }

    function test_shortPaysWhenTheOutcomeLosesIncludingTheMiddleOne() public {
        // Shorting outcome 0 on a three-way book. Outcome 1 — the middle — wins, so the short must
        // pay in full. The middle-winner path is the one most likely to be got wrong.
        vm.prank(alice);
        engine.buyComplement(triple, 0, 40 * UNIT, type(uint256).max);

        _resolveTo(triple, 1);

        vm.prank(alice);
        uint256 paid = engine.redeem(triple);
        assertEq(paid, 40 * UNIT, "a short pays 1 per share when its outcome loses");
    }

    function test_shortPaysNothingWhenTheShortedOutcomeWins() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 40 * UNIT, type(uint256).max);

        _resolveTo(triple, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NothingToClaim.selector));
        engine.redeem(triple);
    }

    // ================================================================== exit

    function test_sellReturnsCollateralAndReducesTheBook() public {
        vm.prank(alice);
        engine.buy(binary, 0, 100 * UNIT, type(uint256).max);

        uint256 balanceBefore = usdc.balanceOf(alice);
        uint256 quoted = engine.quoteSell(binary, 0, 60 * UNIT);

        vm.prank(alice);
        uint256 proceeds = engine.sell(binary, 0, 60 * UNIT, quoted);

        assertEq(proceeds, quoted, "sell quote must match the payout");
        assertEq(usdc.balanceOf(alice) - balanceBefore, proceeds, "collateral actually arrives");
        assertEq(engine.sharesOf(binary, alice, 0), 40 * UNIT, "position reduced, not closed");
        _assertSolvent(binary);
    }

    function test_traderCanFullyExitBeforeResolution() public {
        // The headline difference from a parimutuel pool: money is not trapped until settlement.
        vm.prank(alice);
        engine.buy(binary, 1, 250 * UNIT, type(uint256).max);
        vm.prank(alice);
        engine.sell(binary, 1, 250 * UNIT, 0);

        assertEq(engine.sharesOf(binary, alice, 1), 0, "fully exited");
        assertEq(engine.outcomeShares(binary, 1), SEED, "book returns to its seed");
        _assertSolvent(binary);
    }

    // ================================================================== settlement

    function _resolveTo(uint256 id, uint256 winner) internal {
        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.resolve(id, winner);
    }

    function test_resolveSweepsSurplusAndLeavesExactlyWhatIsOwed() public {
        vm.prank(alice);
        engine.buy(binary, 0, 200 * UNIT, type(uint256).max);

        uint256 owed = engine.outcomeShares(binary, 0);
        uint256 feesBefore = usdc.balanceOf(fees);

        _resolveTo(binary, 0);

        assertEq(engine.collateralOf(binary), owed, "market holds exactly its liability");
        assertGt(usdc.balanceOf(fees) - feesBefore, 0, "surplus swept to the fee recipient");
    }

    function test_winnerRedeemsOneForOne() public {
        vm.prank(alice);
        engine.buy(binary, 0, 200 * UNIT, type(uint256).max);
        _resolveTo(binary, 0);

        vm.prank(alice);
        assertEq(engine.redeem(binary), 200 * UNIT, "winning shares pay exactly 1 each");
    }

    function test_everyWinnerCanBePaidAndTheMarketEndsEmpty() public {
        vm.prank(alice);
        engine.buy(binary, 0, 200 * UNIT, type(uint256).max);
        vm.prank(bob);
        engine.buy(binary, 0, 350 * UNIT, type(uint256).max);
        _resolveTo(binary, 0);

        vm.prank(alice);
        engine.redeem(binary);
        vm.prank(bob);
        engine.redeem(binary);
        vm.prank(admin);
        engine.redeemSeed(binary);

        // Seed + both winners is the entire liability, so nothing should remain.
        assertEq(engine.collateralOf(binary), 0, "market pays out exactly, to the base unit");
    }

    function test_creatorLossIsDeterministicAndOutcomeIndependent() public {
        uint256 spent = 1069_314718; // measured in test_createSeedsTheBookAndChargesTheCreatorABoundedLoss
        _resolveTo(binary, 1); // the outcome does not matter; that is the point
        vm.prank(admin);
        uint256 back = engine.redeemSeed(binary);
        assertEq(back, SEED, "the creator always gets their seed back");
        assertApproxEqAbs(spent - back, 69_314718, 1e4, "loss is b*ln(2), whatever wins");
    }

    function test_invalidateRefundsCostBasis() public {
        vm.prank(alice);
        uint256 paid = engine.buy(binary, 0, 100 * UNIT, type(uint256).max);

        vm.prank(resolver);
        engine.invalidate(binary);

        vm.prank(alice);
        assertEq(engine.redeem(binary), paid, "a voided market returns what was put in");
    }

    // ================================================================== negative

    function test_negative_cannotTradeAfterClose() public {
        vm.warp(closeTime + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketClosed.selector, binary));
        engine.buy(binary, 0, 10 * UNIT, type(uint256).max);
    }

    function test_negative_slippageGuardStopsABadFill() public {
        uint256 quoted = engine.quoteBuy(binary, 0, 100 * UNIT);
        vm.prank(alice);
        vm.expectRevert();
        engine.buy(binary, 0, 100 * UNIT, quoted - 1);
    }

    function test_negative_sellSlippageGuardStopsABadFill() public {
        vm.prank(alice);
        engine.buy(binary, 0, 100 * UNIT, type(uint256).max);
        uint256 quoted = engine.quoteSell(binary, 0, 50 * UNIT);
        vm.prank(alice);
        vm.expectRevert();
        engine.sell(binary, 0, 50 * UNIT, quoted + 1);
    }

    function test_negative_cannotSellMoreThanHeld() public {
        vm.prank(alice);
        engine.buy(binary, 0, 10 * UNIT, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientShares.selector, 10 * UNIT, 11 * UNIT));
        engine.sell(binary, 0, 11 * UNIT, 0);
    }

    function test_negative_cannotSellSomeoneElsesPosition() public {
        vm.prank(alice);
        engine.buy(binary, 0, 10 * UNIT, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InsufficientShares.selector, 0, 5 * UNIT));
        engine.sell(binary, 0, 5 * UNIT, 0);
    }

    function test_negative_cannotBuyZero() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmountZero.selector));
        engine.buy(binary, 0, 0, type(uint256).max);
    }

    function test_negative_cannotBuyAnOutcomeThatDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 2, 2));
        engine.buy(binary, 2, 10 * UNIT, type(uint256).max);
    }

    function test_negative_onlyTheBoundResolverMaySettle() public {
        vm.warp(closeTime + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, alice));
        engine.resolve(binary, 0);
    }

    function test_negative_cannotResolveBeforeClose() public {
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(MarketNotClosed.selector, binary));
        engine.resolve(binary, 0);
    }

    function test_negative_cannotRedeemTwice() public {
        vm.prank(alice);
        engine.buy(binary, 0, 100 * UNIT, type(uint256).max);
        _resolveTo(binary, 0);

        vm.prank(alice);
        engine.redeem(binary);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlreadyClaimed.selector));
        engine.redeem(binary);
    }

    function test_negative_cannotRedeemBeforeSettlement() public {
        vm.prank(alice);
        engine.buy(binary, 0, 100 * UNIT, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketNotResolved.selector, binary));
        engine.redeem(binary);
    }

    function test_negative_loserGetsNothing() public {
        vm.prank(alice);
        engine.buy(binary, 1, 100 * UNIT, type(uint256).max);
        _resolveTo(binary, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NothingToClaim.selector));
        engine.redeem(binary);
    }

    function test_negative_seedIsLockedWhileTrading() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.SeedLocked.selector));
        engine.redeemSeed(binary);
    }

    function test_negative_onlyTheCreatorMayReclaimTheSeed() public {
        _resolveTo(binary, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, alice));
        engine.redeemSeed(binary);
    }

    function test_negative_rejectsTooManyOutcomes() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcomeCount.selector, 5, 2, 4));
        engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 5,
                alpha: ALPHA,
                sStar: S_STAR,
                seedPerOutcome: SEED,
                category: bytes32(0),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    function test_negative_rejectsAlphaOutsideItsBand() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.AlphaOutOfRange.selector, 1e18, 1e15, 1e17));
        engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 2,
                alpha: 1e18,
                sStar: S_STAR,
                seedPerOutcome: SEED,
                category: bytes32(0),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    function test_negative_rejectsASeedBelowTheFloor() public {
        // Below the floor b' diverges and quoted spreads stop being sane.
        vm.prank(admin);
        vm.expectRevert();
        engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 2,
                alpha: ALPHA,
                sStar: S_STAR,
                seedPerOutcome: 1, // 1e-6 USDC per outcome
                category: bytes32(0),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    // ================================================================== regression

    function test_regression_roundTripAlwaysLoses() public {
        // A buy immediately reversed must cost money, or the market is a faucet.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.buy(binary, 0, 100 * UNIT, type(uint256).max);
        vm.prank(alice);
        engine.sell(binary, 0, 100 * UNIT, 0);
        assertLt(usdc.balanceOf(alice), before, "round trip must never profit");
    }

    function test_regression_splittingATradeIsNeverCheaper() public {
        uint256 whole = engine.quoteBuy(binary, 0, 200 * UNIT);

        vm.prank(alice);
        uint256 first = engine.buy(binary, 0, 100 * UNIT, type(uint256).max);
        vm.prank(alice);
        uint256 second = engine.buy(binary, 0, 100 * UNIT, type(uint256).max);

        assertGe(first + second, whole, "chunking must not be a discount");
    }

    function test_regression_shortThenLongIsNotAFreeCompleteSet() public {
        // Buying every outcome guarantees a payout of `sh`; the curve must charge strictly more, or
        // the set could be assembled below par and redeemed at par.
        uint256 sh = 100 * UNIT;
        uint256 legA = engine.quoteBuyComplement(triple, 0, sh); // outcomes 1 and 2
        vm.prank(alice);
        engine.buyComplement(triple, 0, sh, type(uint256).max);
        uint256 legB = engine.quoteBuy(triple, 0, sh);

        assertGt(legA + legB, sh, "a complete set costs more than it redeems");
    }

    function test_regression_positionsAreKeyedOnTheCaller() public {
        // The privacy model depends on this: the holder is msg.sender — the ExecutionAccount —
        // and nothing else. If the engine ever keyed on tx.origin the trader would be exposed.
        vm.prank(alice);
        engine.buy(binary, 0, 10 * UNIT, type(uint256).max);
        assertEq(engine.sharesOf(binary, alice, 0), 10 * UNIT);
        assertEq(engine.sharesOf(binary, tx.origin, 0), 0, "must not credit tx.origin");
    }

    function test_regression_marketsDoNotShareCollateral() public {
        // Per-market isolation: draining one book must not touch another's balance.
        uint256 otherBefore = engine.collateralOf(triple);
        vm.prank(alice);
        engine.buy(binary, 0, 500 * UNIT, type(uint256).max);
        vm.prank(alice);
        engine.sell(binary, 0, 500 * UNIT, 0);
        assertEq(engine.collateralOf(triple), otherBefore, "market B untouched by market A");
    }

    function testFuzz_regression_solventAfterAnySingleTrade(uint256 shares, uint256 outcome, uint256 mode)
        public
    {
        shares = bound(shares, 1, 50_000 * UNIT);
        outcome = bound(outcome, 0, 2);
        mode = bound(mode, 0, 1);

        vm.prank(alice);
        if (mode == 0) {
            engine.buy(triple, outcome, shares, type(uint256).max);
        } else {
            engine.buyComplement(triple, outcome, shares, type(uint256).max);
        }
        _assertSolvent(triple);
    }
}

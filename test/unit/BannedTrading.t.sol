// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../../src/markets/LsLmsrMarket.sol";
import {TradingBlocklist} from "../../src/access/TradingBlocklist.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Roles} from "../../src/access/Roles.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title BannedTradingTest
/// @notice What a ban actually reaches inside the engine, and what it deliberately does not.
///
/// @dev A ban is the one place this protocol takes a right away from a trader on the strength of an
///      operator ruling, so its boundary has to be exact and pinned by tests rather than described
///      in a comment. Two claims are being defended:
///
///      1. A banned account cannot open, add to, or close a position. That is "banned from trading".
///      2. A banned account can still {redeem}. Its positions settle at the honest outcome and it
///         collects them. The penalty is the forfeited bond and the lost access — not confiscation
///         of money won before the lie. An engine that blocked redemption would be seizing property,
///         which is a far larger claim than this system makes.
contract BannedTradingTest is Test {
    LsLmsrMarket internal engine;
    TradingBlocklist internal blocklist;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal fees = address(0xFEE5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;
    uint16 internal constant FEE_BPS = 100; // 1%

    uint256 internal marketId;
    uint64 internal closeTime;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        blocklist = new TradingBlocklist(admin);

        vm.startPrank(admin);
        engine = new LsLmsrMarket(admin, fees, address(0), address(blocklist));
        engine.setTradeFee(FEE_BPS);
        vm.stopPrank();

        closeTime = uint64(block.timestamp + 7 days);
        _fund(admin, 1_000_000 * UNIT);
        _fund(alice, 1_000_000 * UNIT);
        _fund(bob, 1_000_000 * UNIT);

        vm.prank(admin);
        marketId = engine.createMarket(
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

    function _ban(address who) internal {
        vm.prank(admin);
        blocklist.ban(who, address(engine), marketId);
    }

    function _buy(address who, uint256 outcome, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        return engine.buy(marketId, outcome, shares, type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Positive: an unbanned account is completely unaffected
    // ---------------------------------------------------------------------

    function test_unbannedAccountTradesNormally() public {
        _buy(alice, 0, 100 * UNIT);
        assertEq(engine.sharesOf(marketId, alice, 0), 100 * UNIT, "position opened");

        vm.prank(alice);
        engine.sell(marketId, 0, 50 * UNIT, 0);
        assertEq(engine.sharesOf(marketId, alice, 0), 50 * UNIT, "position reduced");
    }

    /// @dev An engine constructed with no list at all must behave exactly as it did before this
    ///      feature existed. The zero address is the off switch, not a broken pointer.
    function test_engineWithoutABlocklistNeverChecks() public {
        vm.startPrank(admin);
        LsLmsrMarket bare = new LsLmsrMarket(admin, fees, address(0), address(0));
        vm.stopPrank();
        assertEq(address(bare.blocklist()), address(0), "no list");

        usdc.mint(alice, 1_000_000 * UNIT);
        vm.prank(alice);
        usdc.approve(address(bare), type(uint256).max);

        vm.prank(admin);
        usdc.approve(address(bare), type(uint256).max);
        vm.prank(admin);
        uint256 id = bare.createMarket(
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

        _ban(alice); // banned on the shared list, which this engine does not read
        vm.prank(alice);
        bare.buy(id, 0, 100 * UNIT, type(uint256).max);
        assertEq(bare.sharesOf(id, alice, 0), 100 * UNIT, "trade went through");
    }

    // ---------------------------------------------------------------------
    // Negative: every trading entry point is closed
    // ---------------------------------------------------------------------

    function test_bannedAccountCannotBuy() public {
        _ban(alice);
        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.AccountBanned.selector, alice));
        vm.prank(alice);
        engine.buy(marketId, 0, 100 * UNIT, type(uint256).max);
    }

    function test_bannedAccountCannotShort() public {
        _ban(alice);
        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.AccountBanned.selector, alice));
        vm.prank(alice);
        engine.buyComplement(marketId, 0, 100 * UNIT, type(uint256).max);
    }

    function test_bannedAccountCannotSell() public {
        _buy(alice, 0, 100 * UNIT);
        _ban(alice);

        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.AccountBanned.selector, alice));
        vm.prank(alice);
        engine.sell(marketId, 0, 50 * UNIT, 0);
    }

    function test_bannedAccountCannotCloseAShort() public {
        vm.prank(alice);
        engine.buyComplement(marketId, 0, 100 * UNIT, type(uint256).max);
        _ban(alice);

        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.AccountBanned.selector, alice));
        vm.prank(alice);
        engine.sellComplement(marketId, 0, 100 * UNIT, 0);
    }

    function test_banOnlyAffectsTheBannedAccount() public {
        _ban(alice);
        _buy(bob, 0, 100 * UNIT);
        assertEq(engine.sharesOf(marketId, bob, 0), 100 * UNIT, "bob is unaffected");
    }

    // ---------------------------------------------------------------------
    // The boundary: settlement stays open
    // ---------------------------------------------------------------------

    /// @dev The claim the whole design rests on. A banned winner still gets paid.
    function test_bannedAccountCanStillRedeemAWin() public {
        _buy(alice, 0, 100 * UNIT);
        _ban(alice);

        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.resolve(marketId, 0);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = engine.redeem(marketId);

        assertEq(paid, 100 * UNIT, "winning shares pay 1:1");
        assertEq(usdc.balanceOf(alice), before + 100 * UNIT, "the money arrived");
    }

    /// @dev And on a voided market, a banned account still gets its cost basis back.
    function test_bannedAccountCanStillRefundFromAVoidedMarket() public {
        uint256 held = engine.collateralOf(marketId);
        _buy(alice, 0, 100 * UNIT);
        // Cost basis is what reached the market, which is the charge minus the fee. Derived from
        // `collateralHeld` rather than re-implementing the engine's rounding in the test.
        uint256 cost = engine.collateralOf(marketId) - held;
        _ban(alice);

        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.invalidate(marketId);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.redeem(marketId);

        assertEq(usdc.balanceOf(alice), before + cost, "cost basis refunded");
    }

    // ---------------------------------------------------------------------
    // Regression
    // ---------------------------------------------------------------------

    /// @dev Lifting a ban has to restore trading with no further step, or an unban would be a
    ///      promise the engine does not keep.
    function test_unbanRestoresTradingImmediately() public {
        _ban(alice);
        vm.prank(admin);
        blocklist.unban(alice);

        _buy(alice, 0, 100 * UNIT);
        assertEq(engine.sharesOf(marketId, alice, 0), 100 * UNIT, "trading again");
    }

    /// @dev The check runs before the quote, so a banned account pays the revert immediately
    ///      rather than after the engine has done the expensive part. Asserted through gas because
    ///      that ordering is otherwise invisible and easy to undo in a refactor.
    function test_bannedTradeRevertsBeforeTheExpensiveWork() public {
        _ban(alice);

        uint256 start = gasleft();
        vm.prank(alice);
        try engine.buy(marketId, 0, 100 * UNIT, type(uint256).max) {
            revert("should have reverted");
        } catch {}
        uint256 used = start - gasleft();

        // A full LS-LMSR quote costs well over 100k. Failing an order of magnitude below that is
        // the observable consequence of checking first.
        assertLt(used, 60_000, "banned trades must fail early");
    }

    // ---------------------------------------------------------------------
    // Per-market fee revenue, which is what a resolution reward is sized against
    // ---------------------------------------------------------------------

    function test_feesAreRecordedPerMarket() public {
        uint256 held = engine.collateralOf(marketId);
        uint256 charged = _buy(alice, 0, 100 * UNIT);
        // What reached the market versus what the trader paid. The gap is the fee, by definition.
        uint256 cost = engine.collateralOf(marketId) - held;

        assertGt(engine.feesOf(marketId), 0, "something was recorded");
        assertEq(engine.feesOf(marketId), charged - cost, "the whole gap is booked to this market");
        assertEq(engine.feesOf(marketId), engine.feeOn(cost), "and agrees with the engine's own rate");
        assertEq(engine.feesOf(marketId), engine.feesAccrued(address(usdc)), "one market, one total");
    }

    function test_feesAccumulateAcrossTradersAndSides() public {
        _buy(alice, 0, 100 * UNIT);
        uint256 afterFirst = engine.feesOf(marketId);

        _buy(bob, 1, 200 * UNIT);
        uint256 afterSecond = engine.feesOf(marketId);
        assertGt(afterSecond, afterFirst, "buys add");

        vm.prank(alice);
        engine.sell(marketId, 0, 50 * UNIT, 0);
        assertGt(engine.feesOf(marketId), afterSecond, "sells add too");
    }

    /// @dev Two markets on one engine must not pool their revenue, or a reward on a quiet market
    ///      would be sized against a busy one's takings.
    function test_marketsDoNotShareFeeRevenue() public {
        vm.prank(admin);
        uint256 second = engine.createMarket(
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

        _buy(alice, 0, 100 * UNIT);
        assertGt(engine.feesOf(marketId), 0, "first market earned");
        assertEq(engine.feesOf(second), 0, "second market earned nothing");

        vm.prank(bob);
        engine.buy(second, 1, 300 * UNIT, type(uint256).max);
        assertGt(engine.feesOf(second), 0, "now it has");
        assertEq(
            engine.feesAccrued(address(usdc)),
            engine.feesOf(marketId) + engine.feesOf(second),
            "the global total is the sum of the parts"
        );
    }

    /// @dev Recording per-market revenue must not disturb the solvency accounting, which is the one
    ///      invariant a fee change could plausibly break.
    function test_perMarketFeesAreNotMarketCollateral() public {
        _buy(alice, 0, 100 * UNIT);
        _buy(bob, 1, 100 * UNIT);

        assertEq(
            usdc.balanceOf(address(engine)),
            engine.collateralOf(marketId) + engine.feesAccrued(address(usdc)),
            "balance is collateral plus fees, and nothing else"
        );
    }

    function test_feesOfIsZeroForAnUntradedMarket() public view {
        assertEq(engine.feesOf(marketId), 0, "seeding is not a trade");
        assertEq(engine.feesOf(999), 0, "and an unknown market has none");
    }

    /// @dev `isSettled` is what stops the resolver bonding a market it can never settle, so its
    ///      three states are worth pinning against the engine itself rather than the mock.
    function test_isSettledTracksTheMarketLifecycle() public {
        assertFalse(engine.isSettled(marketId), "trading");

        vm.warp(closeTime + 1);
        assertFalse(engine.isSettled(marketId), "closed is not settled");

        vm.prank(resolver);
        engine.resolve(marketId, 0);
        assertTrue(engine.isSettled(marketId), "resolved");
    }

    function test_isSettledIsTrueForAVoidedMarket() public {
        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.invalidate(marketId);
        assertTrue(engine.isSettled(marketId), "voided counts as settled");
    }
}

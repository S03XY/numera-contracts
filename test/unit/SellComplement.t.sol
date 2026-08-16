// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../../src/markets/LsLmsrMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {AmountBelowMin, InsufficientShares, SlippageExceeded} from "../../src/libraries/Errors.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title SellComplementTest
/// @notice Closing a short in one call.
///
/// @dev `buyComplement` opens a short by buying one share of every *other* outcome, so closing it
///      means selling every one of those legs. Doing that as separate calls is not acceptable here:
///      under sponsored execution each leg is its own relayed transaction, so a revert on leg two
///      does not leave a rare edge case — it leaves the trader holding an unbalanced remainder that
///      is no longer a short and no longer hedged, as the ordinary consequence of a price move.
///
///      Hence one atomic primitive. The tests below establish that it is (a) equivalent to selling
///      the legs individually, (b) all-or-nothing, and (c) quoted honestly.
contract SellComplementTest is Test {
    LsLmsrMarket internal engine;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal fees = address(0xFEE5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;

    uint256 internal triple;
    uint64 internal closeTime;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(admin);
        engine = new LsLmsrMarket(admin, fees, address(0), address(0));

        closeTime = uint64(block.timestamp + 7 days);
        _fund(admin, 1_000_000 * UNIT);
        _fund(alice, 1_000_000 * UNIT);
        _fund(bob, 1_000_000 * UNIT);

        vm.prank(admin);
        triple = engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 3,
                alpha: 0.010619e18,
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

    // ============================================================== the core equivalence

    function test_isExactlySellingEveryLegInOrder(uint256 sharesRaw) public {
        // The correctness anchor. This primitive exists for atomicity, not for different pricing —
        // if it ever paid differently from the individual sales it replaces, it would be a separate
        // instrument wearing the same name.
        uint256 shares = bound(sharesRaw, 1 * UNIT, 100 * UNIT);

        vm.prank(alice);
        engine.buyComplement(triple, 0, shares, type(uint256).max);
        vm.prank(bob);
        engine.buyComplement(triple, 0, shares, type(uint256).max);

        uint256 snapshot = vm.snapshotState();

        // Path A: one atomic call.
        vm.prank(alice);
        uint256 atomic = engine.sellComplement(triple, 0, shares, 0);

        vm.revertToState(snapshot);

        // Path B: leg by leg, in the same order.
        uint256 individual;
        for (uint256 j = 1; j < 3; ++j) {
            vm.prank(alice);
            individual += engine.sell(triple, j, shares, 0);
        }

        assertEq(atomic, individual, "the basket paid differently from its parts");
    }

    function test_closesEveryLegAndPaysTheTrader() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 20 * UNIT, type(uint256).max);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 proceeds = engine.sellComplement(triple, 0, 20 * UNIT, 0);

        assertEq(usdc.balanceOf(alice) - before, proceeds, "trader was paid something else");
        assertEq(engine.sharesOf(triple, alice, 1), 0, "leg 1 still open");
        assertEq(engine.sharesOf(triple, alice, 2), 0, "leg 2 still open");
        assertEq(engine.sharesOf(triple, alice, 0), 0, "the excluded outcome should never be held");
        _assertSolvent(triple);
    }

    function test_reducesAShortWithoutClosingIt() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 30 * UNIT, type(uint256).max);

        vm.prank(alice);
        engine.sellComplement(triple, 0, 10 * UNIT, 0);

        // Still a short, just a smaller one: every leg must move together or it stops being a hedge.
        assertEq(engine.sharesOf(triple, alice, 1), 20 * UNIT);
        assertEq(engine.sharesOf(triple, alice, 2), 20 * UNIT);
        _assertSolvent(triple);
    }

    // ==================================================================== atomicity

    function test_leavesNothingChangedWhenOneLegCannotBeSold() public {
        // The whole reason this primitive exists. A trader whose legs are uneven — from a partial
        // sale, or a leg bought separately — must not end up with the sellable ones gone and the
        // rest stranded.
        vm.prank(alice);
        engine.buyComplement(triple, 0, 20 * UNIT, type(uint256).max);
        vm.prank(alice);
        engine.sell(triple, 2, 5 * UNIT, 0); // leg 2 now holds less than leg 1

        uint256 leg1 = engine.sharesOf(triple, alice, 1);
        uint256 leg2 = engine.sharesOf(triple, alice, 2);
        uint256 balance = usdc.balanceOf(alice);
        uint256 collateral = engine.collateralOf(triple);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientShares.selector, leg2, 20 * UNIT));
        engine.sellComplement(triple, 0, 20 * UNIT, 0);

        assertEq(engine.sharesOf(triple, alice, 1), leg1, "leg 1 was sold despite the revert");
        assertEq(engine.sharesOf(triple, alice, 2), leg2, "leg 2 changed");
        assertEq(usdc.balanceOf(alice), balance, "money moved despite the revert");
        assertEq(engine.collateralOf(triple), collateral, "market collateral changed");
    }

    function test_respectsTheSlippageFloorOverTheWholeBasket() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 20 * UNIT, type(uint256).max);

        uint256 quoted = engine.quoteSellComplement(triple, 0, 20 * UNIT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, quoted, quoted + 1));
        engine.sellComplement(triple, 0, 20 * UNIT, quoted + 1);
    }

    // ======================================================================= quoting

    function test_theQuoteIsWhatTheTraderActuallyReceives() public {
        // A quote summed from independent per-leg prices would overstate the total, because each
        // leg sells into the book the previous one left behind. The UI shows this number.
        vm.prank(alice);
        engine.buyComplement(triple, 0, 25 * UNIT, type(uint256).max);

        uint256 quoted = engine.quoteSellComplement(triple, 0, 25 * UNIT);
        vm.prank(alice);
        uint256 proceeds = engine.sellComplement(triple, 0, 25 * UNIT, 0);

        assertEq(proceeds, quoted, "quote did not match execution");
    }

    function test_theQuoteIsNetOfFees() public {
        vm.startPrank(admin);
        engine.setTradeFee(100); // 1%
        vm.stopPrank();

        vm.prank(alice);
        engine.buyComplement(triple, 0, 25 * UNIT, type(uint256).max);

        uint256 quoted = engine.quoteSellComplement(triple, 0, 25 * UNIT);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        engine.sellComplement(triple, 0, 25 * UNIT, 0);

        assertEq(usdc.balanceOf(alice) - before, quoted, "quote was not net of the fee");
        assertGt(engine.feesAccrued(address(usdc)), 0, "no fee was taken");
        _assertSolvent(triple);
    }

    // ================================================================== the minimum

    function test_aCompleteExitIsExemptFromTheMinimum() public {
        // Open first, then raise the floor above the position's value. Otherwise the floor blocks
        // the opening trade and the exemption is never reached.
        vm.prank(alice);
        engine.buyComplement(triple, 0, 20 * UNIT, type(uint256).max);

        vm.startPrank(admin);
        engine.setTradeFee(100);
        engine.setMinTradeCost(address(usdc), 500 * UNIT);
        vm.stopPrank();

        vm.prank(alice);
        uint256 proceeds = engine.sellComplement(triple, 0, 20 * UNIT, 0);

        assertLt(proceeds, 500 * UNIT, "this case no longer exercises the exemption");
        assertEq(engine.sharesOf(triple, alice, 1), 0, "a complete exit was refused");
    }

    function test_aPartialCloseBelowTheMinimumIsRefused() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 40 * UNIT, type(uint256).max);

        vm.startPrank(admin);
        engine.setTradeFee(100);
        engine.setMinTradeCost(address(usdc), 50 * UNIT);
        vm.stopPrank();

        // Read the quote before pranking: a call in the middle would consume the prank, and
        // `sellComplement` would then run as this test contract — which holds no shares and fails
        // for an entirely different reason.
        uint256 quoted = engine.quoteSellComplement(triple, 0, 2 * UNIT);
        assertLt(quoted, 50 * UNIT, "this case no longer sits below the floor");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmountBelowMin.selector, quoted, 50 * UNIT));
        engine.sellComplement(triple, 0, 2 * UNIT, 0);
    }

    // ======================================================================= settlement

    function test_aClosedShortLeavesNothingToRedeem() public {
        vm.prank(alice);
        engine.buyComplement(triple, 0, 20 * UNIT, type(uint256).max);
        vm.prank(alice);
        engine.sellComplement(triple, 0, 20 * UNIT, 0);

        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.resolve(triple, 1);

        vm.prank(alice);
        vm.expectRevert();
        engine.redeem(triple);
    }
}

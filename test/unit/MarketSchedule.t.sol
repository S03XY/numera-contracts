// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../../src/markets/LsLmsrMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {
    InvalidStartTime,
    MarketClosed,
    MarketNotOpenYet,
    MetadataMismatch
} from "../../src/libraries/Errors.sol";

// The copy a fixture market publishes. Deliberately looks like the real canonical encoding, which
// is a JSON array of [key, value] pairs — see `backend/src/admin/metadata-hash.ts`.
string constant RULES = "[[\"title\",\"Argentina vs France\"],[\"resolutionRules\",\"Settles to the winner at full time.\"]]";

/// @title MarketScheduleTest
/// @notice When a market opens, and why its published rules can never move afterwards.
///
/// @dev Two changes are covered here and they answer two different questions a bettor asks.
///
///      **When can I bet?** The engine used to carry a close and no open, so a market was tradeable
///      from the instant its creating transaction mined. A book could not be announced in advance,
///      and `--closes-in` was the only handle anyone had on its life.
///
///      **What am I betting on?** The rules were committed as a hash and served from a database
///      that an operator could edit. The hash made a *mismatch* detectable by anyone who bothered
///      to re-encode and compare; it did not put the words themselves anywhere durable. Now the
///      canonical copy is published in the creation transaction and checked against the commitment
///      before it is stored, so the rules are as permanent as the market.
contract MarketScheduleTest is Test {
    LsLmsrMarket internal engine;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal fees = address(0xFEE5);
    address internal alice = address(0xA1);

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;
    uint256 internal constant ALPHA = 0.025e18;
    uint256 internal constant S_STAR = 2000e18;

    uint64 internal closeTime;

    event MarketMetadataPublished(uint256 indexed marketId, bytes32 indexed metadataHash, string metadata);

    function setUp() public {
        // Away from the genesis timestamp, so "a start time in the past" is expressible.
        vm.warp(1_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(admin);
        engine = new LsLmsrMarket(admin, fees, address(0), address(0));
        closeTime = uint64(block.timestamp + 7 days);

        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? admin : alice;
            usdc.mint(who, 1_000_000 * UNIT);
            vm.prank(who);
            usdc.approve(address(engine), type(uint256).max);
        }
    }

    function _params(uint64 startTime, string memory metadata, bytes32 commitment)
        internal
        view
        returns (LsLmsrMarket.CreateParams memory)
    {
        return LsLmsrMarket.CreateParams({
            collateral: address(usdc),
            resolver: resolver,
            startTime: startTime,
            closeTime: closeTime,
            outcomeCount: 2,
            alpha: ALPHA,
            sStar: S_STAR,
            seedPerOutcome: SEED,
            category: bytes32("SPORTS"),
            metadataHash: commitment,
            metadata: metadata
        });
    }

    function _create(uint64 startTime) internal returns (uint256 id) {
        vm.prank(admin);
        id = engine.createMarket(_params(startTime, RULES, keccak256(bytes(RULES))));
    }

    // ============================================================ start time: positive

    function test_aScheduledMarketIsNotTradeableBeforeItOpens() public {
        uint64 opensAt = uint64(block.timestamp + 1 hours);
        uint256 id = _create(opensAt);

        assertEq(engine.getMarket(id).startTime, opensAt, "start time not stored");
        assertFalse(engine.getMarket(id).tradingOpen, "a scheduled market must not read as open");

        vm.warp(opensAt);
        assertTrue(engine.getMarket(id).tradingOpen, "should open exactly at the start time");
    }

    function test_tradingWorksNormallyOnceOpen() public {
        uint64 opensAt = uint64(block.timestamp + 1 hours);
        uint256 id = _create(opensAt);

        vm.warp(opensAt + 1);
        vm.prank(alice);
        engine.buy(id, 0, 10 * UNIT, type(uint256).max);

        assertGt(engine.sharesOf(id, alice, 0), 0, "a bet after the open must land");
    }

    function test_zeroMeansOpenNow_andIsStoredAsARealInstant() public {
        // Stored rather than left as a sentinel, so no reader has to know that zero means now and
        // every market has an opening instant it can display.
        uint256 id = _create(0);

        assertEq(engine.getMarket(id).startTime, uint64(block.timestamp), "zero should resolve to now");
        assertTrue(engine.getMarket(id).tradingOpen, "an unscheduled market opens immediately");
    }

    // ============================================================ start time: negative

    function test_buyingBeforeTheOpenReverts() public {
        uint64 opensAt = uint64(block.timestamp + 1 hours);
        uint256 id = _create(opensAt);

        vm.expectRevert(abi.encodeWithSelector(MarketNotOpenYet.selector, id, opensAt));
        vm.prank(alice);
        engine.buy(id, 0, 10 * UNIT, type(uint256).max);
    }

    function test_sellingBeforeTheOpenReverts() public {
        // Every trading entry point shares one gate, so this pins that the gate is in the shared
        // helper rather than bolted onto `buy` alone.
        uint64 opensAt = uint64(block.timestamp + 1 hours);
        uint256 id = _create(opensAt);

        vm.expectRevert(abi.encodeWithSelector(MarketNotOpenYet.selector, id, opensAt));
        vm.prank(alice);
        engine.sell(id, 0, 1 * UNIT, 0);
    }

    function test_aMarketCannotOpenAfterItCloses() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidStartTime.selector, closeTime + 1, closeTime));
        engine.createMarket(_params(closeTime + 1, RULES, keccak256(bytes(RULES))));
    }

    function test_aMarketCannotOpenAtTheMomentItCloses() public {
        // Equal times would create a book with a zero-width trading window: open and shut in the
        // same second, and payable by nobody.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidStartTime.selector, closeTime, closeTime));
        engine.createMarket(_params(closeTime, RULES, keccak256(bytes(RULES))));
    }

    function test_aMarketCannotBeBackdated() public {
        uint64 past = uint64(block.timestamp - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidStartTime.selector, past, closeTime));
        engine.createMarket(_params(past, RULES, keccak256(bytes(RULES))));
    }

    // ============================================================ start time: regression

    function test_theViewNeverOffersATradeTheEngineWillRefuse() public {
        // The exact shape of bug this pairing exists to prevent: `tradingOpen` is what the UI draws
        // its buy button from, so a view that disagrees with the gate produces a button that always
        // fails. Checked on both sides of the open and again at the close.
        uint64 opensAt = uint64(block.timestamp + 1 hours);
        uint256 id = _create(opensAt);

        assertFalse(engine.getMarket(id).tradingOpen);
        _assertBuyReverts(id);

        vm.warp(opensAt);
        assertTrue(engine.getMarket(id).tradingOpen);

        vm.warp(closeTime);
        assertFalse(engine.getMarket(id).tradingOpen, "closed must still read closed");
        vm.expectRevert(abi.encodeWithSelector(MarketClosed.selector, id));
        vm.prank(alice);
        engine.buy(id, 0, 10 * UNIT, type(uint256).max);
    }

    function _assertBuyReverts(uint256 id) internal {
        vm.expectRevert();
        vm.prank(alice);
        engine.buy(id, 0, 10 * UNIT, type(uint256).max);
    }

    // ============================================================ metadata: positive

    function test_theRulesArePublishedInFullOnChain() public {
        vm.expectEmit(true, true, false, true);
        emit MarketMetadataPublished(0, keccak256(bytes(RULES)), RULES);

        vm.prank(admin);
        engine.createMarket(_params(0, RULES, keccak256(bytes(RULES))));
    }

    function test_theStoredCommitmentMatchesThePublishedCopy() public {
        uint256 id = _create(0);
        assertEq(engine.getMarket(id).metadataHash, keccak256(bytes(RULES)), "commitment must match the copy");
    }

    // ============================================================ metadata: negative

    function test_copyThatDoesNotHashToItsCommitmentIsRejected() public {
        // The whole guarantee in one test. Without this check a market could commit to one rule set
        // and publish another, and every later verification would be against the wrong bytes.
        bytes32 wrong = keccak256("some other rules");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MetadataMismatch.selector, keccak256(bytes(RULES)), wrong));
        engine.createMarket(_params(0, RULES, wrong));
    }

    function test_emptyCopyCannotBeSlippedPastTheCheck() public {
        // A market with a real-looking commitment and no published rules would satisfy anyone who
        // only checked that a hash existed.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(MetadataMismatch.selector, keccak256(bytes("")), keccak256(bytes(RULES)))
        );
        engine.createMarket(_params(0, "", keccak256(bytes(RULES))));
    }

    // ============================================================ metadata: regression

    function test_nothingCanChangeTheRulesAfterAnyoneHasBet() public {
        uint256 id = _create(0);
        bytes32 atCreation = engine.getMarket(id).metadataHash;

        vm.prank(alice);
        engine.buy(id, 0, 10 * UNIT, type(uint256).max);
        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.resolve(id, 0);

        assertEq(engine.getMarket(id).metadataHash, atCreation, "the commitment moved");
    }

    function test_twoMarketsCanPublishDifferentRules() public {
        // Guards against a shared-storage slip where the second market's copy overwrites the first.
        string memory other = "[[\"title\",\"Something else entirely\"]]";
        uint256 a = _create(0);
        vm.prank(admin);
        uint256 b = engine.createMarket(_params(0, other, keccak256(bytes(other))));

        assertEq(engine.getMarket(a).metadataHash, keccak256(bytes(RULES)));
        assertEq(engine.getMarket(b).metadataHash, keccak256(bytes(other)));
    }
}

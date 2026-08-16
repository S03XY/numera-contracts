// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../../src/markets/LsLmsrMarket.sol";
import {OptimisticResolver} from "../../src/resolvers/OptimisticResolver.sol";
import {ResolverMultisig} from "../../src/resolvers/ResolverMultisig.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {TradingBlocklist} from "../../src/access/TradingBlocklist.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Roles} from "../../src/access/Roles.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title ResolutionLifecycleTest
/// @notice The whole thing wired together: real engine, real quorum, real ban list, no mocks.
///
/// @dev Every other suite tests one contract against stand-ins. This one exists because the parts
///      that break in production are the seams — a role granted in the wrong order, a settlement
///      that reaches the engine but not the ban list, a reward sized against the wrong market. So
///      this deploys exactly what `script/Deploy.s.sol` deploys, wires it exactly the same way, and
///      runs markets through it end to end.
///
///      The wiring under test includes the revocation the deploy script performs: after setup the
///      operator holds **no** `RESOLVER_ROLE` on {TrustedResolver}, so it has no route into the
///      engine that skips the dispute window. That is what makes "an operator proposal can be
///      challenged like anyone else's" a property rather than a promise.
contract ResolutionLifecycleTest is Test {
    LsLmsrMarket internal engine;
    OptimisticResolver internal resolver;
    ResolverMultisig internal multisig;
    TrustedResolver internal trusted;
    TradingBlocklist internal blocklist;
    MockERC20 internal usdc;

    address internal operator = makeAddr("operator");
    address internal trustedWallet = makeAddr("trustedWallet");
    address internal signerOne = makeAddr("signerOne");
    address internal signerTwo = makeAddr("signerTwo");
    address internal feeSink = makeAddr("feeSink");

    address internal alice = makeAddr("alice"); // proposes falsely, holds both sides
    address internal bob = makeAddr("bob"); // disputes, and is right
    address internal carol = makeAddr("carol"); // an ordinary trader

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1_000 * UNIT;
    uint16 internal constant TRADE_FEE_BPS = 100; // 1%
    uint256 internal constant POOL = 5_000 * UNIT;

    uint64 internal closeTime;
    uint256 internal marketId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(block.timestamp + 7 days);

        blocklist = new TradingBlocklist(operator);
        trusted = new TrustedResolver(operator);

        address[] memory signers = new address[](2);
        signers[0] = signerOne;
        signers[1] = signerTwo;
        multisig = new ResolverMultisig(operator, signers, 2);

        // No relay in this suite: the forwarder has its own, and `address(0)` here means every call
        // below is a direct one, which is what an operator wallet does anyway.
        OptimisticResolver.Parameters memory p;
        p.bond = 25 * UNIT;
        p.proposalFee = 1 * UNIT;
        p.disputeWindow = 6 hours;
        p.arbitrationTimeout = 3 days;
        p.rewardBps = 200; // 2% of the market's own fee revenue
        p.rewardCap = 50 * UNIT;

        resolver = new OptimisticResolver(
            operator, address(multisig), address(0), address(usdc), address(trusted), address(blocklist), p
        );

        vm.startPrank(operator);
        engine = new LsLmsrMarket(operator, feeSink, address(0), address(blocklist));
        engine.setTradeFee(TRADE_FEE_BPS);

        // The wiring from `_wireAuthority` in the deploy script, in the same order.
        trusted.grantRole(Roles.RESOLVER_ROLE, address(resolver));
        blocklist.grantRole(Roles.BLOCKLIST_ROLE, address(resolver));
        multisig.addTarget(address(resolver));
        resolver.grantRole(Roles.RESOLVER_ROLE, trustedWallet);
        trusted.revokeRole(Roles.RESOLVER_ROLE, operator);
        vm.stopPrank();

        _fund(operator, 1_000_000 * UNIT);
        _fund(alice, 100_000 * UNIT);
        _fund(bob, 100_000 * UNIT);
        _fund(carol, 100_000 * UNIT);

        vm.startPrank(alice);
        usdc.approve(address(resolver), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(resolver), type(uint256).max);
        vm.stopPrank();

        usdc.mint(address(resolver), POOL);
        marketId = _createMarket(bytes32("meta1"));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(engine), type(uint256).max);
    }

    function _createMarket(bytes32 meta) internal returns (uint256) {
        vm.prank(operator);
        return engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(trusted),
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

    function _buy(address who, uint256 id, uint256 outcome, uint256 shares) internal {
        vm.prank(who);
        engine.buy(id, outcome, shares, type(uint256).max);
    }

    /// @dev Run a call through the quorum: one signer raises it, the other confirms, and the second
    ///      confirmation executes it. This is what arbitration actually looks like in production.
    function _throughTheQuorum(bytes memory data) internal {
        vm.prank(signerOne);
        uint256 id = multisig.propose(address(resolver), data);
        vm.prank(signerTwo);
        multisig.confirm(id);
    }

    // =====================================================================
    // The contested path, end to end
    // =====================================================================

    function test_falseProposalIsOverturned_liarSlashedAndBanned_watcherPaid() public {
        // Alice takes both sides; bob takes the one that will win.
        _buy(alice, marketId, 0, 2_000 * UNIT);
        _buy(alice, marketId, 1, 400 * UNIT);
        _buy(bob, marketId, 1, 3_000 * UNIT);

        uint256 revenue = engine.feesOf(marketId);
        assertGt(revenue, 0, "the market earned something to pay a reward out of");

        vm.warp(closeTime + 1);
        uint256 bond = resolver.bond();

        // Alice lies in favour of the side she is heaviest on.
        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);

        vm.prank(bob);
        resolver.dispute(address(engine), marketId, 1);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        _throughTheQuorum(abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1)));

        // The engine actually settled, to the truth.
        assertTrue(engine.isSettled(marketId), "market settled");
        assertEq(engine.getMarket(marketId).winningOutcomeId, 1, "settled to the disputed answer");

        // The money moved the way the design says it should.
        uint256 reward = (revenue * 200) / 10_000;
        assertEq(usdc.balanceOf(alice), aliceBefore, "the liar gets nothing back");
        assertEq(usdc.balanceOf(bob), bobBefore + bond + reward, "the watcher takes stake plus reward");

        // And the ban landed, engine-side.
        assertTrue(blocklist.isBanned(alice), "liar barred");
        assertFalse(blocklist.isBanned(bob), "watcher untouched");
    }

    /// @dev The forfeited stake stays with the platform rather than going to the winner, and it is
    ///      the reward pool it lands in — which is what makes the pool partly self-funding.
    function test_forfeitedStakeFundsTheRewardPool() public {
        _buy(alice, marketId, 0, 2_000 * UNIT);
        _buy(bob, marketId, 1, 2_000 * UNIT);
        vm.warp(closeTime + 1);

        uint256 bond = resolver.bond();
        uint256 poolBefore = resolver.rewardPool();
        uint256 reward = (engine.feesOf(marketId) * 200) / 10_000;

        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);
        vm.prank(bob);
        resolver.dispute(address(engine), marketId, 1);
        _throughTheQuorum(abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1)));

        assertEq(resolver.rewardPool(), poolBefore + bond - reward, "took a bond in, paid a reward out");
    }

    // =====================================================================
    // What a ban actually costs, on a real engine
    // =====================================================================

    function test_bannedAccountIsLockedOutOfEveryMarketButStillRedeems() public {
        _buy(alice, marketId, 0, 2_000 * UNIT);
        _buy(alice, marketId, 1, 500 * UNIT); // the position that will win
        _buy(bob, marketId, 1, 2_000 * UNIT);

        vm.warp(closeTime + 1);
        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);
        vm.prank(bob);
        resolver.dispute(address(engine), marketId, 1);
        _throughTheQuorum(abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1)));
        assertTrue(blocklist.isBanned(alice), "banned");

        // A different market, on the same engine, created after the ban. Still closed to her.
        vm.warp(closeTime - 1 days);
        uint256 second = _createMarket(bytes32("meta2"));
        vm.expectRevert(abi.encodeWithSelector(LsLmsrMarket.AccountBanned.selector, alice));
        vm.prank(alice);
        engine.buy(second, 0, 100 * UNIT, type(uint256).max);

        // But the money she won before the lie is still hers.
        vm.warp(closeTime + 1);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = engine.redeem(marketId);

        assertEq(paid, 500 * UNIT, "her winning shares pay 1:1");
        assertEq(usdc.balanceOf(alice), before + 500 * UNIT, "and the money arrived");
    }

    function test_banDoesNotDisturbOtherTraders() public {
        _buy(alice, marketId, 0, 2_000 * UNIT);
        _buy(bob, marketId, 1, 2_000 * UNIT);
        vm.warp(closeTime + 1);

        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);
        vm.prank(bob);
        resolver.dispute(address(engine), marketId, 1);
        _throughTheQuorum(abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1)));

        vm.warp(closeTime - 1 days);
        uint256 second = _createMarket(bytes32("meta3"));
        _buy(carol, second, 0, 500 * UNIT);
        assertEq(engine.sharesOf(second, carol, 0), 500 * UNIT, "carol is unaffected");
    }

    // =====================================================================
    // The operator's bond-free path
    // =====================================================================

    function test_trustedWalletSettlesQuicklyWithNoBond() public {
        _buy(alice, marketId, 0, 1_000 * UNIT);
        _buy(bob, marketId, 1, 1_000 * UNIT);
        vm.warp(closeTime + 1);

        vm.prank(trustedWallet);
        resolver.propose(address(engine), marketId, 0);
        assertEq(usdc.balanceOf(trustedWallet), 0, "it never needed a balance");

        vm.warp(block.timestamp + 6 hours + 1);
        resolver.finalize(address(engine), marketId);

        assertTrue(engine.isSettled(marketId), "settled");
        assertEq(resolver.rewardPool(), POOL, "no reward paid for a bond-free proposal");
    }

    /// @dev The claim the whole "operator can resolve too" design has to survive: its proposal is
    ///      not final. A trader disputes it, the quorum overturns it, and the trader is paid.
    function test_aTraderCanOverturnTheOperator() public {
        _buy(alice, marketId, 0, 1_000 * UNIT);
        _buy(bob, marketId, 1, 1_000 * UNIT);
        vm.warp(closeTime + 1);

        vm.prank(trustedWallet);
        resolver.propose(address(engine), marketId, 0);

        uint256 bond = resolver.bond();
        uint256 reward = (engine.feesOf(marketId) * 200) / 10_000;

        vm.prank(bob);
        resolver.dispute(address(engine), marketId, 1);
        uint256 bobBefore = usdc.balanceOf(bob);

        _throughTheQuorum(abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1)));

        assertTrue(engine.isSettled(marketId), "settled to the trader's answer");
        assertEq(usdc.balanceOf(bob), bobBefore + bond + reward, "the trader is paid for being right");
        assertFalse(blocklist.isBanned(trustedWallet), "an operator wallet is never banned");
    }

    // =====================================================================
    // The seams themselves
    // =====================================================================

    /// @dev The revocation is the load-bearing line of the deploy script. If it ever stops
    ///      happening, the operator quietly regains a settlement path that skips the whole layer.
    function test_operatorCannotSettleAroundTheLayer() public {
        vm.warp(closeTime + 1);
        vm.expectRevert();
        vm.prank(operator);
        trusted.resolveMarket(address(engine), marketId, 0);
    }

    /// @dev Only the quorum arbitrates. A lone signer cannot, and neither can the operator.
    function test_arbitrationNeedsTheWholeQuorum() public {
        _buy(alice, marketId, 0, 1_000 * UNIT);
        vm.warp(closeTime + 1);
        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);

        bytes memory call = abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1));

        // One confirmation is not enough at a threshold of two.
        vm.prank(signerOne);
        multisig.propose(address(resolver), call);
        assertFalse(engine.isSettled(marketId), "nothing happened yet");

        // The operator is not a signer, and holds no arbitrator role of its own.
        vm.expectRevert();
        vm.prank(operator);
        resolver.arbitrate(address(engine), marketId, 1);
    }

    /// @dev The quorum's reach is exactly one contract. It cannot touch the engine, the ban list or
    ///      the resolver that markets are bound to.
    function test_quorumCannotReachAnythingButTheResolver() public {
        vm.prank(signerOne);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.TargetNotAllowed.selector, address(engine)));
        multisig.propose(address(engine), abi.encodeCall(LsLmsrMarket.pause, ()));

        vm.prank(signerOne);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverMultisig.TargetNotAllowed.selector, address(blocklist))
        );
        multisig.propose(address(blocklist), abi.encodeCall(TradingBlocklist.ban, (carol, address(0), 0)));
    }

    /// @dev A market still trading cannot be proposed on, whoever asks.
    function test_nothingSettlesBeforeCloseTime() public {
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.MarketNotClosed.selector, address(engine), marketId)
        );
        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.MarketNotClosed.selector, address(engine), marketId)
        );
        vm.prank(trustedWallet);
        resolver.propose(address(engine), marketId, 0);
    }

    /// @dev Conservation over the whole lifecycle, against the real engine. If the resolver ever
    ///      pays out of a bond, or the engine ever counts a resolution fee as collateral, this is
    ///      where it shows up.
    function test_noValueIsCreatedOrDestroyed() public {
        _buy(alice, marketId, 0, 2_000 * UNIT);
        _buy(bob, marketId, 1, 2_000 * UNIT);
        vm.warp(closeTime + 1);

        vm.prank(alice);
        resolver.propose(address(engine), marketId, 0);
        vm.prank(bob);
        resolver.dispute(address(engine), marketId, 1);
        _throughTheQuorum(abi.encodeCall(OptimisticResolver.arbitrate, (address(engine), marketId, 1)));

        assertEq(
            usdc.balanceOf(address(resolver)),
            resolver.bondedTotal() + resolver.feesAccrued() + resolver.rewardPool(),
            "resolver holds exactly bonds + fees + pool"
        );
        assertEq(
            usdc.balanceOf(address(engine)),
            engine.collateralOf(marketId) + engine.feesAccrued(address(usdc)),
            "engine holds exactly collateral + fees"
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PrivateOptimisticResolver} from "../../src/resolvers/PrivateOptimisticResolver.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockOptimisticMarket} from "../../src/mocks/MockOptimisticMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Roles} from "../../src/access/Roles.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Settlement by bonded proposal: who gets paid, who gets slashed, and what happens when
///         nobody shows up on either side.
///
/// @dev The economics are the security model here. A pseudonymous proposer cannot be punished by
///      reputation, so every test that matters is a test about money moving to the right address.
contract PrivateOptimisticResolverTest is Test {
    PrivateOptimisticResolver resolver;
    TrustedResolver trusted;
    MockOptimisticMarket market;
    MockERC20 usdc;

    address operator = makeAddr("operator");
    address alice = makeAddr("alice"); // a market account proposing
    address bob = makeAddr("bob"); // a market account disputing
    address treasury = makeAddr("treasury");
    address forwarder = makeAddr("forwarder");

    uint256 constant USDC = 1e6;
    uint256 constant BOND = 50 * USDC;
    uint64 constant DISPUTE_WINDOW = 6 hours;
    uint64 constant ARBITRATION_TIMEOUT = 7 days;
    uint16 constant REWARD_BPS = 100; // 1%
    uint256 constant REWARD_CAP = 25 * USDC;
    uint256 constant POT = 10_000 * USDC;
    uint256 constant POOL = 1_000 * USDC;

    uint64 closeTime;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(block.timestamp + 1 days);

        trusted = new TrustedResolver(operator);
        resolver = new PrivateOptimisticResolver(
            operator,
            forwarder,
            address(usdc),
            address(trusted),
            BOND,
            DISPUTE_WINDOW,
            ARBITRATION_TIMEOUT,
            REWARD_BPS,
            REWARD_CAP
        );

        // The resolver settles THROUGH the trusted resolver, so it needs the role there. This is the
        // grant the multisig performs on the live deployment.
        vm.prank(operator);
        trusted.grantRole(Roles.RESOLVER_ROLE, address(resolver));

        market = new MockOptimisticMarket(address(trusted), closeTime, 3, POT);

        address[2] memory bonders = [alice, bob];
        for (uint256 i = 0; i < bonders.length; ++i) {
            usdc.mint(bonders[i], 1_000 * USDC);
            vm.prank(bonders[i]);
            usdc.approve(address(resolver), type(uint256).max);
        }
        usdc.mint(address(resolver), POOL); // the operator's reward funding

        vm.warp(closeTime);
    }

    // ----- construction -----

    function test_constructor_grantsOperatorBothRoles() public view {
        assertTrue(resolver.hasRole(resolver.DEFAULT_ADMIN_ROLE(), operator));
        assertTrue(resolver.hasRole(Roles.RESOLVER_ROLE, operator));
        assertEq(resolver.bond(), BOND);
        assertEq(resolver.rewardPool(), POOL);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new PrivateOptimisticResolver(
            address(0), forwarder, address(usdc), address(trusted),
            BOND, DISPUTE_WINDOW, ARBITRATION_TIMEOUT, REWARD_BPS, REWARD_CAP
        );
    }

    // ----- the unchallenged path -----

    function test_propose_locksTheBondAndOpensAWindow() public {
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        resolver.propose(address(market), 1, 2);

        assertEq(usdc.balanceOf(alice), before - BOND);
        assertEq(resolver.bondedTotal(), BOND);
        // Reward funding is untouched by a bond arriving.
        assertEq(resolver.rewardPool(), POOL);

        PrivateOptimisticResolver.Proposal memory p = resolver.getProposal(address(market), 1);
        assertEq(uint8(p.phase), uint8(PrivateOptimisticResolver.Phase.Proposed));
        assertEq(p.proposer, alice);
        assertEq(p.outcome, 2);
        assertEq(p.disputeDeadline, closeTime + DISPUTE_WINDOW);
    }

    function test_finalize_settlesAndPaysTheProposer() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 2);
        uint256 afterBond = usdc.balanceOf(alice);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), 1);

        assertTrue(market.resolved());
        assertEq(market.lastWinningOutcome(), 2);

        // 1% of a 10,000 pot is 100, capped at 25.
        assertEq(usdc.balanceOf(alice), afterBond + BOND + REWARD_CAP);
        assertEq(resolver.bondedTotal(), 0);
        assertEq(resolver.rewardPool(), POOL - REWARD_CAP);
    }

    function test_finalize_rewardIsAShareOfThePotWhenUnderTheCap() public {
        market.setPot(1_000 * USDC); // 1% = 10 USDC, below the 25 cap
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        uint256 afterBond = usdc.balanceOf(alice);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), 1);

        assertEq(usdc.balanceOf(alice), afterBond + BOND + 10 * USDC);
    }

    function test_finalize_revertsWhileTheWindowIsOpen() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.DisputeWindowOpen.selector, closeTime + DISPUTE_WINDOW
            )
        );
        resolver.finalize(address(market), 1);
        assertFalse(market.resolved());
    }

    /// @dev Anyone may finalize, and the reward still goes to the proposer on record. That is what
    ///      lets it stay unrelayed without leaking who proposed.
    function test_finalize_isPermissionlessAndPaysTheRecordedProposer() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 1);
        uint256 afterBond = usdc.balanceOf(alice);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        vm.prank(makeAddr("stranger"));
        resolver.finalize(address(market), 1);

        assertEq(usdc.balanceOf(alice), afterBond + BOND + REWARD_CAP);
    }

    function test_propose_voidsAMarketWithTheSentinel() public {
        // Read the sentinel BEFORE the prank: vm.prank applies to the next call, and a view call
        // would spend it, sending the proposal from the test contract instead of alice.
        uint256 invalid = resolver.INVALID_OUTCOME();
        vm.prank(alice);
        resolver.propose(address(market), 1, invalid);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), 1);
        assertTrue(market.invalidated());
    }

    // ----- proposal guards -----

    function test_propose_revertsBeforeClose() public {
        vm.warp(closeTime - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.MarketNotClosed.selector, address(market), 1
            )
        );
        resolver.propose(address(market), 1, 0);
    }

    function test_propose_revertsOnOutcomeOutOfRange() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PrivateOptimisticResolver.OutcomeOutOfRange.selector, 3, 3)
        );
        resolver.propose(address(market), 1, 3);
    }

    /// @dev First proposal wins. A second is pointless work whose only effect would be to split the
    ///      reward between people who agree, so it is refused outright.
    function test_propose_refusesASecondProposalOnTheSameMarket() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.ProposalExists.selector, address(market), 1
            )
        );
        resolver.propose(address(market), 1, 1);
    }

    // ----- the disputed path -----

    function test_dispute_locksASecondBondAndFreezesTheOutcome() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        vm.prank(bob);
        resolver.dispute(address(market), 1);

        assertEq(resolver.bondedTotal(), BOND * 2);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PrivateOptimisticResolver.NoProposal.selector, address(market), 1)
        );
        resolver.finalize(address(market), 1);
        assertFalse(market.resolved());
    }

    function test_dispute_revertsAfterTheWindowCloses() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.NotDisputable.selector, address(market), 1
            )
        );
        resolver.dispute(address(market), 1);
    }

    /// @dev The case that pays for the whole design: a liar proposes, a watcher catches them, and
    ///      the watcher takes the liar's money on top of their own bond back.
    function test_arbitrate_slashesAWrongProposerAndPaysTheDisputer() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0); // false
        vm.prank(bob);
        resolver.dispute(address(market), 1);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 bobAfter = usdc.balanceOf(bob);

        vm.prank(operator);
        resolver.arbitrate(address(market), 1, 2); // the truth

        assertTrue(market.resolved());
        assertEq(market.lastWinningOutcome(), 2);
        assertEq(usdc.balanceOf(alice), aliceAfter, "liar recovers nothing");
        assertEq(usdc.balanceOf(bob), bobAfter + BOND * 2 + REWARD_CAP, "watcher takes both bonds");
        assertEq(resolver.bondedTotal(), 0);
    }

    /// @dev And the mirror: disputing an honest proposal costs the disputer their bond, which is
    ///      what stops "dispute everything" being a free option.
    function test_arbitrate_slashesAFrivolousDisputerAndPaysTheProposer() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 2); // true
        vm.prank(bob);
        resolver.dispute(address(market), 1);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 bobAfter = usdc.balanceOf(bob);

        vm.prank(operator);
        resolver.arbitrate(address(market), 1, 2);

        assertEq(usdc.balanceOf(bob), bobAfter, "frivolous disputer recovers nothing");
        assertEq(usdc.balanceOf(alice), aliceAfter + BOND * 2 + REWARD_CAP);
    }

    /// @dev A third outcome means the proposal that was about to settle was wrong, so the dispute
    ///      did its job even though the disputer never named a replacement.
    function test_arbitrate_treatsAThirdOutcomeAsTheDisputerBeingRight() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        vm.prank(bob);
        resolver.dispute(address(market), 1);
        uint256 bobAfter = usdc.balanceOf(bob);

        vm.prank(operator);
        resolver.arbitrate(address(market), 1, 1);

        assertEq(usdc.balanceOf(bob), bobAfter + BOND * 2 + REWARD_CAP);
    }

    function test_arbitrate_revertsForNonOperator() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        vm.prank(bob);
        resolver.dispute(address(market), 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, Roles.RESOLVER_ROLE
            )
        );
        resolver.arbitrate(address(market), 1, 0);
    }

    function test_arbitrate_revertsWhenNothingIsDisputed() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.NotDisputed.selector, address(market), 1
            )
        );
        resolver.arbitrate(address(market), 1, 0);
    }

    // ----- the operator's own path -----

    function test_resolveUnproposed_settlesWithNoBondAndNoReward() public {
        uint256 poolBefore = resolver.rewardPool();
        vm.prank(operator);
        resolver.resolveUnproposed(address(market), 1, 1);

        assertTrue(market.resolved());
        assertEq(market.lastWinningOutcome(), 1);
        assertEq(resolver.rewardPool(), poolBefore, "no reward for the operator");
    }

    /// @dev Settling around a live proposal would strand its bond, so the operator is refused and
    ///      pointed at {arbitrate} instead.
    function test_resolveUnproposed_refusesWhileAProposalStands() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.ProposalExists.selector, address(market), 1
            )
        );
        resolver.resolveUnproposed(address(market), 1, 1);
    }

    // ----- liveness -----

    function test_resetStuckDispute_returnsBothBondsWhenTheOperatorGoesQuiet() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        vm.prank(bob);
        resolver.dispute(address(market), 1);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 bobAfter = usdc.balanceOf(bob);

        vm.warp(block.timestamp + ARBITRATION_TIMEOUT + 1);
        resolver.resetStuckDispute(address(market), 1);

        assertEq(usdc.balanceOf(alice), aliceAfter + BOND);
        assertEq(usdc.balanceOf(bob), bobAfter + BOND);
        assertEq(resolver.bondedTotal(), 0);
        assertFalse(market.resolved(), "an unruled dispute settles nothing");

        // And the market is open for business again.
        vm.prank(alice);
        resolver.propose(address(market), 1, 2);
    }

    function test_resetStuckDispute_revertsBeforeTheTimeout() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        vm.prank(bob);
        resolver.dispute(address(market), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.ArbitrationNotTimedOut.selector,
                uint64(block.timestamp) + ARBITRATION_TIMEOUT
            )
        );
        resolver.resetStuckDispute(address(market), 1);
    }

    /// @dev The catch-all. If a market gets settled by some other route, {finalize} can never
    ///      succeed and the bond would be locked forever without this.
    function test_abandonProposal_freesABondWhoseMarketCanNoLongerBeSettled() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);

        // Somebody settles the market behind this contract's back.
        vm.prank(operator);
        trusted.resolveMarket(address(market), 1, 2);

        vm.warp(closeTime + DISPUTE_WINDOW + ARBITRATION_TIMEOUT + 1);
        vm.expectRevert(); // finalize can never work again
        resolver.finalize(address(market), 1);

        uint256 aliceAfter = usdc.balanceOf(alice);
        resolver.abandonProposal(address(market), 1);
        assertEq(usdc.balanceOf(alice), aliceAfter + BOND, "bond recovered, no reward");
        assertEq(resolver.bondedTotal(), 0);
    }

    function test_abandonProposal_revertsBeforeExpiry() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.ProposalNotExpired.selector,
                closeTime + DISPUTE_WINDOW + ARBITRATION_TIMEOUT
            )
        );
        resolver.abandonProposal(address(market), 1);
    }

    // ----- the reward pool cannot eat bonds -----

    /// @dev The invariant that keeps this contract solvent: a reward is only ever paid out of
    ///      collateral that is not somebody's bond.
    function test_rewardNeverComesOutOfABond() public {
        // Drain the pool so only bonds remain.
        vm.prank(operator);
        resolver.withdrawRewardPool(treasury, POOL);
        assertEq(resolver.rewardPool(), 0);

        vm.prank(alice);
        resolver.propose(address(market), 1, 2);
        uint256 afterBond = usdc.balanceOf(alice);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), 1);

        // Bond back, reward zero — never a partial payment carved out of the bond.
        assertEq(usdc.balanceOf(alice), afterBond + BOND);
        assertEq(usdc.balanceOf(address(resolver)), 0);
    }

    function test_withdrawRewardPool_cannotReachLockedBonds() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 0);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivateOptimisticResolver.InsufficientFreeBalance.selector, POOL + BOND, POOL
            )
        );
        resolver.withdrawRewardPool(treasury, POOL + BOND);
    }

    function test_rewardIsCappedByWhateverThePoolCanCover() public {
        vm.prank(operator);
        resolver.withdrawRewardPool(treasury, POOL - 5 * USDC); // 5 USDC left

        vm.prank(alice);
        resolver.propose(address(market), 1, 2);
        uint256 afterBond = usdc.balanceOf(alice);

        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), 1);
        assertEq(usdc.balanceOf(alice), afterBond + BOND + 5 * USDC);
    }

    // ----- administration -----

    function test_setParameters_appliesToNewProposalsOnly() public {
        vm.prank(alice);
        resolver.propose(address(market), 1, 2);

        vm.prank(operator);
        resolver.setParameters(999 * USDC, 1 hours, 1 days, 0, 0);

        // The standing proposal keeps the bond it actually posted.
        vm.warp(closeTime + DISPUTE_WINDOW + 1);
        uint256 afterBond = usdc.balanceOf(alice);
        resolver.finalize(address(market), 1);
        assertEq(usdc.balanceOf(alice), afterBond + BOND, "old bond honoured, new reward rate of 0");
    }

    function test_setParameters_rejectsARewardRateAboveTheCeiling() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PrivateOptimisticResolver.RewardTooHigh.selector, 501, 500)
        );
        resolver.setParameters(BOND, DISPUTE_WINDOW, ARBITRATION_TIMEOUT, 501, REWARD_CAP);
    }

    function test_setParameters_rejectsAZeroDisputeWindow() public {
        vm.prank(operator);
        vm.expectRevert(PrivateOptimisticResolver.WindowZero.selector);
        resolver.setParameters(BOND, 0, ARBITRATION_TIMEOUT, REWARD_BPS, REWARD_CAP);
    }

    function test_setParameters_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        resolver.setParameters(BOND, DISPUTE_WINDOW, ARBITRATION_TIMEOUT, REWARD_BPS, REWARD_CAP);
    }
}

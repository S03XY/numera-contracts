// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OptimisticResolver} from "../../src/resolvers/OptimisticResolver.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {TradingBlocklist} from "../../src/access/TradingBlocklist.sol";
import {MockOptimisticMarket} from "../../src/mocks/MockOptimisticMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Roles} from "../../src/access/Roles.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";

/// @title OptimisticResolverTest
/// @notice Settlement by bonded proposal: who gets paid, who gets slashed, who loses the right to
///         trade, and what happens when nobody shows up on either side.
///
/// @dev The economics are the security model here. A pseudonymous proposer cannot be punished by
///      reputation, so almost every test that matters is a test about money moving to the right
///      address — and, now, about the right account being barred afterwards.
contract OptimisticResolverTest is Test {
    OptimisticResolver internal resolver;
    TrustedResolver internal trusted;
    TradingBlocklist internal blocklist;
    MockOptimisticMarket internal market;
    MockERC20 internal usdc;

    address internal operator = makeAddr("operator");
    address internal arbitrator = makeAddr("arbitrator"); // stands in for the multisig
    address internal trustedWallet = makeAddr("trustedWallet"); // proposes without a bond
    address internal alice = makeAddr("alice"); // a market account proposing
    address internal bob = makeAddr("bob"); // a market account disputing
    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");

    uint256 internal constant USDC = 1e6;

    uint256 internal constant BOND = 25 * USDC;
    uint256 internal constant FEE = 1 * USDC;
    uint64 internal constant DISPUTE_WINDOW = 6 hours;
    uint64 internal constant ARBITRATION_TIMEOUT = 3 days;
    uint16 internal constant REWARD_BPS = 200; // 2% of the market's own fee revenue
    uint256 internal constant REWARD_CAP = 50 * USDC;

    uint256 internal constant POT = 10_000 * USDC;
    uint256 internal constant REVENUE = 500 * USDC; // → a 10 USDC reward, under the cap
    uint256 internal constant REWARD = 10 * USDC;
    uint256 internal constant POOL = 1_000 * USDC;

    uint256 internal constant MARKET_ID = 0;
    uint64 internal closeTime;

    /// @dev Read once in {setUp} rather than inline. `resolver.INVALID_OUTCOME()` is an external
    ///      call, so evaluating it as an argument inside a pranked statement spends the prank on the
    ///      view and sends the real call from this contract instead.
    uint256 internal VOID;

    event Proposed(
        address indexed market,
        uint256 indexed marketId,
        address indexed proposer,
        uint256 outcome,
        uint256 bond,
        uint256 fee,
        bool bonded,
        uint64 disputeDeadline
    );
    event Finalized(
        address indexed market,
        uint256 indexed marketId,
        uint256 outcome,
        address indexed proposer,
        uint256 reward
    );
    event Arbitrated(
        address indexed market,
        uint256 indexed marketId,
        uint256 outcome,
        address indexed winner,
        address loser,
        uint256 forfeited,
        uint256 reward
    );
    event Slashed(
        address indexed market, uint256 indexed marketId, address indexed account, uint256 amount, bool banned
    );

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(block.timestamp + 1 days);

        blocklist = new TradingBlocklist(operator);
        trusted = new TrustedResolver(operator);
        resolver = new OptimisticResolver(
            operator, arbitrator, forwarder, address(usdc), address(trusted), address(blocklist), _params()
        );

        vm.startPrank(operator);
        // Settles through the trusted resolver, so it needs the role there. This is the grant the
        // deploy script performs, alongside revoking the operator's own.
        trusted.grantRole(Roles.RESOLVER_ROLE, address(resolver));
        trusted.revokeRole(Roles.RESOLVER_ROLE, operator);
        // Writes bans when arbitration finds someone lied.
        blocklist.grantRole(Roles.BLOCKLIST_ROLE, address(resolver));
        // A wallet the operator trusts to propose quickly, without a bond.
        resolver.grantRole(Roles.RESOLVER_ROLE, trustedWallet);
        vm.stopPrank();

        market = new MockOptimisticMarket(address(trusted), closeTime, 3, POT);
        market.setFees(REVENUE);
        VOID = resolver.INVALID_OUTCOME();

        address[2] memory bonders = [alice, bob];
        for (uint256 i = 0; i < bonders.length; ++i) {
            usdc.mint(bonders[i], 1_000 * USDC);
            vm.prank(bonders[i]);
            usdc.approve(address(resolver), type(uint256).max);
        }
        usdc.mint(address(resolver), POOL); // the operator's reward funding

        vm.warp(closeTime);
    }

    function _params() internal pure returns (OptimisticResolver.Parameters memory p) {
        p.bond = BOND;
        p.proposalFee = FEE;
        p.disputeWindow = DISPUTE_WINDOW;
        p.arbitrationTimeout = ARBITRATION_TIMEOUT;
        p.rewardBps = REWARD_BPS;
        p.rewardCap = REWARD_CAP;
    }

    function _get() internal view returns (OptimisticResolver.Proposal memory) {
        return resolver.getProposal(address(market), MARKET_ID);
    }

    // =====================================================================
    // Construction and parameters
    // =====================================================================

    function test_constructor_wiresEveryRole() public view {
        assertTrue(resolver.hasRole(resolver.DEFAULT_ADMIN_ROLE(), operator), "operator is admin");
        assertTrue(resolver.hasRole(Roles.RESOLVER_ROLE, operator), "operator proposes bond-free");
        assertTrue(resolver.hasRole(Roles.ARBITRATOR_ROLE, arbitrator), "quorum arbitrates");
        assertFalse(resolver.hasRole(Roles.ARBITRATOR_ROLE, operator), "operator does not arbitrate");
        assertEq(resolver.rewardPool(), POOL, "pool funded");
    }

    /// @dev The property the deploy script asserts: after wiring, the operator has no direct route
    ///      into the engine, so an operator proposal really is subject to the dispute window.
    function test_operatorHasNoDirectSettlementPath() public view {
        assertFalse(trusted.hasRole(Roles.RESOLVER_ROLE, operator), "operator cannot settle directly");
        assertTrue(trusted.hasRole(Roles.RESOLVER_ROLE, address(resolver)), "only the layer can");
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ZeroAddress.selector);
        new OptimisticResolver(
            address(0), arbitrator, forwarder, address(usdc), address(trusted), address(blocklist), _params()
        );

        vm.expectRevert(ZeroAddress.selector);
        new OptimisticResolver(
            operator, address(0), forwarder, address(usdc), address(trusted), address(blocklist), _params()
        );
    }

    function test_setParameters_rejectsOutOfRangeValues() public {
        OptimisticResolver.Parameters memory p = _params();

        p.rewardBps = 5_001;
        vm.expectRevert(abi.encodeWithSelector(OptimisticResolver.RewardTooHigh.selector, 5_001, 5_000));
        vm.prank(operator);
        resolver.setParameters(p);

        p = _params();
        p.disputeWindow = 0;
        vm.expectRevert(OptimisticResolver.WindowZero.selector);
        vm.prank(operator);
        resolver.setParameters(p);
    }

    function test_setParameters_isAdminOnly() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, bytes32(0)
            )
        );
        vm.prank(alice);
        resolver.setParameters(_params());
    }

    // =====================================================================
    // Bond sizing: flat
    // =====================================================================

    /// @dev The whole claim, and the reason the pot-scaling it replaced was dropped: a bond deters
    ///      spam and puts skin in the game, and neither has a reason to grow with the book. A
    ///      proposer can therefore know the cost before opening the market.
    function test_bondIsTheSameWhateverTheMarketHolds() public {
        assertEq(resolver.bond(), BOND, "as configured");

        market.setPot(100 * USDC);
        assertEq(resolver.bond(), BOND, "unchanged on a tiny market");

        market.setPot(10_000_000 * USDC);
        assertEq(resolver.bond(), BOND, "unchanged on an enormous one");
    }

    /// @dev Regression on the removal itself. The resolver used to read `collateralOf` to price a
    ///      bond; nothing should read it now, so an engine that cannot answer must still be
    ///      proposable at the full stake rather than falling back to some floor.
    function test_bondSurvivesAnEngineThatCannotReportItsPot() public {
        market.setViewsBroken(true);
        assertEq(resolver.bond(), BOND, "no engine read left to fail");
    }

    // =====================================================================
    // Proposing: the public path
    // =====================================================================

    function test_propose_locksTheBondTakesTheFeeAndOpensAWindow() public {
        uint256 before = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(resolver));
        emit Proposed(
            address(market), MARKET_ID, alice, 1, BOND, FEE, true, uint64(block.timestamp) + DISPUTE_WINDOW
        );
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        assertEq(usdc.balanceOf(alice), before - BOND - FEE, "bond and fee both leave");
        assertEq(resolver.bondedTotal(), BOND, "only the bond is bonded");
        assertEq(resolver.feesAccrued(), FEE, "the fee is the operator's");
        assertEq(resolver.rewardPool(), POOL, "neither touched the reward pool");

        OptimisticResolver.Proposal memory p = _get();
        assertEq(uint8(p.phase), uint8(OptimisticResolver.Phase.Proposed), "phase");
        assertEq(p.proposer, alice, "proposer recorded");
        assertTrue(p.proposerBonded, "bonded");
        assertEq(p.outcome, 1, "outcome");
        assertEq(p.proposerBond, BOND, "bond snapshotted");
        assertEq(p.disputeDeadline, uint64(block.timestamp) + DISPUTE_WINDOW, "window");
    }

    function test_propose_acceptsTheVoidSentinel() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, VOID);
        assertEq(_get().outcome, uint32(VOID), "void recorded");
    }

    /// @dev The bond is snapshotted at propose time so a later parameter change cannot strand or
    ///      inflate a stake somebody has already posted.
    function test_propose_snapshotsTheBondAgainstLaterChanges() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        OptimisticResolver.Parameters memory p = _params();
        p.bond = 900 * USDC;
        vm.prank(operator);
        resolver.setParameters(p);

        assertEq(_get().proposerBond, BOND, "the posted stake is unchanged");
    }

    function test_propose_rejectsAMarketStillTrading() public {
        vm.warp(closeTime - 1);
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.MarketNotClosed.selector, address(market), MARKET_ID)
        );
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
    }

    function test_propose_rejectsAnOutcomeOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(OptimisticResolver.OutcomeOutOfRange.selector, 3, 3));
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 3);
    }

    function test_propose_rejectsASecondProposal() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.ProposalExists.selector, address(market), MARKET_ID)
        );
        vm.prank(bob);
        resolver.propose(address(market), MARKET_ID, 2);
    }

    /// @dev Regression. Without the settled check a stranger could bond a market that was already
    ///      resolved, and the stake would sit locked until the abandon timeout for nothing.
    function test_propose_rejectsAnAlreadySettledMarket() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        // A different market id on the same settled mock: the phase record is clear, so only the
        // engine's own view can catch this.
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.MarketAlreadySettled.selector, address(market), 1)
        );
        vm.prank(bob);
        resolver.propose(address(market), 1, 1);
    }

    function test_propose_failsWithoutAllowance() public {
        address broke = makeAddr("broke");
        usdc.mint(broke, 1_000 * USDC);
        vm.expectRevert();
        vm.prank(broke);
        resolver.propose(address(market), MARKET_ID, 1);
    }

    // =====================================================================
    // Proposing: the operator and its trusted wallets
    // =====================================================================

    function test_trustedWalletProposesWithoutBondOrFee() public {
        vm.prank(trustedWallet);
        resolver.propose(address(market), MARKET_ID, 1);

        OptimisticResolver.Proposal memory p = _get();
        assertFalse(p.proposerBonded, "no stake");
        assertEq(p.proposerBond, 0, "no bond");
        assertEq(resolver.bondedTotal(), 0, "nothing bonded");
        assertEq(resolver.feesAccrued(), 0, "no fee charged");
        assertEq(usdc.balanceOf(trustedWallet), 0, "the wallet never needed a balance");
    }

    /// @dev The whole point of the design: a bond-free proposal buys speed, not finality.
    function test_operatorProposalOpensTheSameDisputeWindow() public {
        vm.prank(operator);
        resolver.propose(address(market), MARKET_ID, 1);

        assertEq(_get().disputeDeadline, uint64(block.timestamp) + DISPUTE_WINDOW, "identical window");

        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        assertEq(uint8(_get().phase), uint8(OptimisticResolver.Phase.Disputed), "challengeable");
    }

    /// @dev Disputing a bond-free proposal must still cost something, or suspending settlement
    ///      would be free and therefore a denial-of-service primitive.
    function test_disputingABondFreeProposalStillCostsABond() public {
        vm.prank(operator);
        resolver.propose(address(market), MARKET_ID, 1);

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        assertEq(usdc.balanceOf(bob), before - BOND - FEE, "priced fresh from the pot");
        assertEq(_get().disputerBond, BOND, "recorded");
        assertEq(resolver.bondedTotal(), BOND, "only the disputer is bonded");
    }

    // =====================================================================
    // Disputing
    // =====================================================================

    function test_dispute_matchesTheProposersStake() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        assertEq(usdc.balanceOf(bob), before - BOND - FEE, "equal bond plus the fee");
        assertEq(resolver.bondedTotal(), BOND * 2, "both stakes held");
        assertEq(resolver.feesAccrued(), FEE * 2, "two fees");

        OptimisticResolver.Proposal memory p = _get();
        assertEq(p.disputer, bob, "disputer recorded");
        assertEq(p.counterOutcome, 2, "counter recorded");
        assertEq(p.arbitrationDeadline, uint64(block.timestamp) + ARBITRATION_TIMEOUT, "clock reset");
    }

    /// @dev Regression. The disputer matches what the proposer actually staked, not whatever the
    ///      bond happens to be now — otherwise an operator raising it mid-window would let one side
    ///      be outspent by the other.
    function test_dispute_isNotRepricedWhenTheBondChanges() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        OptimisticResolver.Parameters memory params = _params();
        params.bond = 900 * USDC;
        vm.prank(operator);
        resolver.setParameters(params);

        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        assertEq(_get().disputerBond, BOND, "matched, not re-priced");
    }

    function test_dispute_rejectsTheSameOutcome() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.expectRevert(abi.encodeWithSelector(OptimisticResolver.SameOutcome.selector, 1));
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 1);
    }

    function test_dispute_rejectsAnOutcomeOutOfRange() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.expectRevert(abi.encodeWithSelector(OptimisticResolver.OutcomeOutOfRange.selector, 9, 3));
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 9);
    }

    function test_dispute_rejectsAfterTheWindowCloses() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NotDisputable.selector, address(market), MARKET_ID)
        );
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
    }

    function test_dispute_rejectsWhenNothingWasProposed() public {
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NotDisputable.selector, address(market), MARKET_ID)
        );
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
    }

    /// @dev The window is inclusive of its final second. A dispute landing exactly on the deadline
    ///      is in time, and an off-by-one here would silently discard the last block of the window.
    function test_dispute_isAcceptedOnTheDeadlineItself() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.warp(_get().disputeDeadline);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        assertEq(uint8(_get().phase), uint8(OptimisticResolver.Phase.Disputed), "in time");
    }

    function test_dispute_cannotBeRaisedTwice() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NotDisputable.selector, address(market), MARKET_ID)
        );
        vm.prank(alice);
        resolver.dispute(address(market), MARKET_ID, 0);
    }

    // =====================================================================
    // Finalizing an unchallenged proposal
    // =====================================================================

    function test_finalize_settlesAndPaysTheProposer() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(resolver));
        emit Finalized(address(market), MARKET_ID, 1, alice, REWARD);
        resolver.finalize(address(market), MARKET_ID);

        assertTrue(market.resolved(), "engine settled");
        assertEq(market.lastWinningOutcome(), 1, "to the proposed outcome");
        assertEq(usdc.balanceOf(alice), before + BOND + REWARD, "bond back plus the reward");
        assertEq(resolver.bondedTotal(), 0, "nothing left bonded");
        assertEq(resolver.rewardPool(), POOL - REWARD, "reward came out of the pool");
        assertEq(uint8(_get().phase), uint8(OptimisticResolver.Phase.Settled), "terminal");
    }

    function test_finalize_voidsTheMarketOnTheSentinel() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, VOID);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        assertTrue(market.invalidated(), "voided");
        assertFalse(market.resolved(), "not resolved");
    }

    /// @dev A trusted wallet is paid for running the platform, not per settlement. Its bond-free
    ///      proposal returns nothing because it staked nothing.
    function test_finalize_paysNothingForABondFreeProposal() public {
        vm.prank(trustedWallet);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        assertTrue(market.resolved(), "still settles");
        assertEq(usdc.balanceOf(trustedWallet), 0, "no reward");
        assertEq(resolver.rewardPool(), POOL, "pool untouched");
    }

    function test_finalize_isPermissionless() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(makeAddr("passerby"));
        resolver.finalize(address(market), MARKET_ID);

        assertEq(usdc.balanceOf(alice), before + BOND + REWARD, "paid the recorded proposer");
    }

    function test_finalize_rejectsWhileTheWindowIsOpen() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.DisputeWindowOpen.selector, _get().disputeDeadline)
        );
        resolver.finalize(address(market), MARKET_ID);
    }

    function test_finalize_rejectsADisputedProposal() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NoProposal.selector, address(market), MARKET_ID)
        );
        resolver.finalize(address(market), MARKET_ID);
    }

    function test_finalize_cannotRunTwice() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NoProposal.selector, address(market), MARKET_ID)
        );
        resolver.finalize(address(market), MARKET_ID);
    }

    // =====================================================================
    // Arbitration of a disputed market
    // =====================================================================

    function test_arbitrate_proposerRight_slashesAndBansTheDisputer() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.expectEmit(true, true, true, true, address(resolver));
        emit Slashed(address(market), MARKET_ID, bob, BOND, true);
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);

        assertEq(market.lastWinningOutcome(), 1, "settled to the proposal");
        assertEq(usdc.balanceOf(alice), aliceBefore + BOND + REWARD, "winner: stake back plus reward");
        assertEq(usdc.balanceOf(bob), bobBefore, "loser gets nothing back");
        assertTrue(blocklist.isBanned(bob), "loser barred from trading");
        assertFalse(blocklist.isBanned(alice), "winner untouched");
        assertEq(resolver.bondedTotal(), 0, "both stakes released from the ledger");
    }

    /// @dev The forfeited stake is the platform's, not the winner's. It stays in the contract and
    ///      becomes reward pool, which is what "the money is taken" means in this design.
    function test_arbitrate_forfeitedBondBecomesRewardPool() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);

        // The pool started at POOL, paid one REWARD out, and took bob's whole BOND in.
        assertEq(resolver.rewardPool(), POOL - REWARD + BOND, "slashed stake lands in the pool");
    }

    function test_arbitrate_proposerWrong_slashesAndBansTheProposer() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);

        assertEq(market.lastWinningOutcome(), 2, "settled to the disputer's answer");
        assertEq(usdc.balanceOf(bob), bobBefore + BOND + REWARD, "disputer paid");
        assertEq(usdc.balanceOf(alice), aliceBefore, "proposer forfeits");
        assertTrue(blocklist.isBanned(alice), "proposer barred");
        assertFalse(blocklist.isBanned(bob), "disputer untouched");
    }

    /// @dev A third outcome neither side named. The dispute was still justified — the proposal that
    ///      would otherwise have settled was wrong — so the disputer keeps their stake and is not
    ///      banned, but is not paid for an answer they did not get right either.
    function test_arbitrate_thirdOutcome_disputerKeepsStakeButEarnsNoReward() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 0);

        assertEq(usdc.balanceOf(bob), bobBefore + BOND, "stake back, no reward");
        assertFalse(blocklist.isBanned(bob), "right to object");
        assertTrue(blocklist.isBanned(alice), "proposer still lied");
        assertEq(resolver.rewardPool(), POOL + BOND, "no reward paid; alice's stake taken");
    }

    function test_arbitrate_canVoidAContestedMarket() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, VOID);

        assertTrue(market.invalidated(), "voided");
        assertTrue(blocklist.isBanned(alice), "proposer was wrong");
        assertFalse(blocklist.isBanned(bob), "disputer was right to object");
    }

    /// @dev A bond-free operator proposal overturned by the quorum forfeits nothing and bans
    ///      nobody, because there was no stake and the wallet is not a market account. That
    ///      asymmetry is real, and pinning it here stops it being quietly "fixed" into a ban on an
    ///      operator wallet.
    function test_arbitrate_overturningTheOperatorCostsTheOperatorNothing() public {
        vm.prank(trustedWallet);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);

        assertFalse(blocklist.isBanned(trustedWallet), "the operator wallet is not banned");
        assertEq(usdc.balanceOf(bob), bobBefore + BOND + REWARD, "the disputer is still paid");
        assertEq(resolver.bondedTotal(), 0, "ledger clear");
    }

    function test_arbitrate_upholdingTheOperatorSlashesTheDisputer() public {
        vm.prank(trustedWallet);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);

        assertTrue(blocklist.isBanned(bob), "wrong disputer barred");
        assertEq(resolver.rewardPool(), POOL + BOND, "their stake taken, no reward owed");
    }

    // =====================================================================
    // Arbitration as an override of an undisputed proposal
    // =====================================================================

    /// @dev The operator's way to correct a mistake nobody happened to notice. Without it, a wrong
    ///      proposal that draws no dispute settles wrongly and permanently.
    function test_arbitrate_overridesAnUndisputedProposal() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);

        assertEq(market.lastWinningOutcome(), 2, "settled to the truth");
        assertEq(usdc.balanceOf(alice), before, "the wrong proposer forfeits");
        assertTrue(blocklist.isBanned(alice), "and is barred");
        assertEq(resolver.rewardPool(), POOL + BOND, "no winner to pay");
    }

    function test_arbitrate_upholdingAnUndisputedProposalPaysIt() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);

        assertEq(usdc.balanceOf(alice), before + BOND + REWARD, "same as finalizing");
        assertFalse(blocklist.isBanned(alice), "not banned");
    }

    function test_arbitrate_canOverrideBeforeTheWindowEvenCloses() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        assertGt(_get().disputeDeadline, block.timestamp, "window still open");

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);
        assertTrue(market.resolved(), "settled anyway");
    }

    // =====================================================================
    // Arbitration: access and preconditions
    // =====================================================================

    function test_arbitrate_isQuorumOnly() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, Roles.ARBITRATOR_ROLE
            )
        );
        vm.prank(operator);
        resolver.arbitrate(address(market), MARKET_ID, 2);
    }

    function test_arbitrate_rejectsAMarketWithNoProposal() public {
        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NotArbitrable.selector, address(market), MARKET_ID)
        );
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);
    }

    function test_arbitrate_rejectsAnAlreadySettledMarket() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.NotArbitrable.selector, address(market), MARKET_ID)
        );
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);
    }

    function test_arbitrate_rejectsAnOutcomeOutOfRange() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.expectRevert(abi.encodeWithSelector(OptimisticResolver.OutcomeOutOfRange.selector, 7, 3));
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 7);
    }

    /// @dev Regression. A settlement must never be blocked by the ban step, so a resolver that has
    ///      lost `BLOCKLIST_ROLE` still arbitrates — it simply cannot bar anyone.
    function test_arbitrate_stillSettlesWhenBanningIsNotPermitted() public {
        vm.prank(operator);
        blocklist.revokeRole(Roles.BLOCKLIST_ROLE, address(resolver));

        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.expectEmit(true, true, true, true, address(resolver));
        emit Slashed(address(market), MARKET_ID, bob, BOND, false);
        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);

        assertTrue(market.resolved(), "settlement went through");
        assertFalse(blocklist.isBanned(bob), "but nobody was banned");
    }

    /// @dev Same claim for the other failure: an account already barred from an earlier market must
    ///      not make the second arbitration revert.
    function test_arbitrate_stillSettlesWhenTheLoserIsAlreadyBanned() public {
        vm.prank(operator);
        blocklist.ban(bob, address(0), 0);

        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 1);
        assertTrue(market.resolved(), "settled");
    }

    // =====================================================================
    // Rewards and pool accounting
    // =====================================================================

    function test_rewardIsAShareOfTheMarketsOwnFeeRevenue() public view {
        assertEq(resolver.rewardFor(address(market), MARKET_ID), REWARD, "2% of 500 USDC");
    }

    function test_rewardIsCapped() public {
        market.setFees(1_000_000 * USDC); // 2% = 20k USDC, far above the cap
        assertEq(resolver.rewardFor(address(market), MARKET_ID), REWARD_CAP, "capped");
    }

    function test_rewardIsZeroWhenTheMarketEarnedNothing() public {
        market.setFees(0);
        assertEq(resolver.rewardFor(address(market), MARKET_ID), 0, "no revenue, no share");
    }

    /// @dev A reward is a nicety; a settlement is not. An empty pool must not block one.
    function test_finalize_settlesEvenWithAnEmptyRewardPool() public {
        vm.prank(operator);
        resolver.withdrawRewardPool(treasury, POOL);
        assertEq(resolver.rewardPool(), 0, "drained");

        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 before = usdc.balanceOf(alice);
        resolver.finalize(address(market), MARKET_ID);

        assertTrue(market.resolved(), "settled");
        assertEq(usdc.balanceOf(alice), before + BOND, "bond back, no reward");
    }

    /// @dev Regression, and the reason `_payout` adds `principal` back to the committed figure by
    ///      hand: a bond that is about to be repaid must never read as free reward pool, or it
    ///      would be paid out twice and the next bonder would be short.
    function test_rewardIsNeverPaidOutOfSomebodysBond() public {
        vm.prank(operator);
        resolver.withdrawRewardPool(treasury, POOL);

        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.propose(address(market), 1, 1); // a second market, a second bond in the contract

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        uint256 aliceBefore = usdc.balanceOf(alice);
        resolver.finalize(address(market), MARKET_ID);

        assertEq(usdc.balanceOf(alice), aliceBefore + BOND, "no reward taken from bob's stake");
        assertEq(resolver.bondedTotal(), BOND, "bob's stake still fully held");
        assertEq(
            usdc.balanceOf(address(resolver)),
            resolver.bondedTotal() + resolver.feesAccrued(),
            "balance is exactly what is owed"
        );
    }

    function test_withdrawRewardPool_cannotReachBondsOrFees() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        uint256 free = resolver.rewardPool();
        assertEq(free, POOL, "bond and fee excluded");

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.InsufficientFreeBalance.selector, free + 1, free)
        );
        vm.prank(operator);
        resolver.withdrawRewardPool(treasury, free + 1);
    }

    function test_sweepFees_collectsExactlyTheCharges() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.prank(operator);
        resolver.sweepFees(treasury);

        assertEq(usdc.balanceOf(treasury), FEE * 2, "both fees");
        assertEq(resolver.feesAccrued(), 0, "ledger cleared");
        assertEq(resolver.bondedTotal(), BOND * 2, "bonds untouched");
    }

    function test_fundRewardPool_recordsTheTopUp() public {
        usdc.mint(operator, 100 * USDC);
        vm.startPrank(operator);
        usdc.approve(address(resolver), 100 * USDC);
        resolver.fundRewardPool(100 * USDC);
        vm.stopPrank();

        assertEq(resolver.rewardPool(), POOL + 100 * USDC, "pool grew");
    }

    // =====================================================================
    // Liveness backstops
    // =====================================================================

    function test_resetStuckDispute_returnsBothStakes() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.warp(block.timestamp + ARBITRATION_TIMEOUT + 1);
        resolver.resetStuckDispute(address(market), MARKET_ID);

        assertEq(usdc.balanceOf(alice), aliceBefore + BOND, "proposer whole");
        assertEq(usdc.balanceOf(bob), bobBefore + BOND, "disputer whole");
        assertEq(resolver.bondedTotal(), 0, "ledger clear");
        assertEq(uint8(_get().phase), uint8(OptimisticResolver.Phase.None), "market reopens");
        assertFalse(market.resolved(), "nothing was settled");
    }

    /// @dev The fees are not returned: the service was used, whatever the quorum did afterwards.
    function test_resetStuckDispute_keepsTheFees() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        vm.warp(block.timestamp + ARBITRATION_TIMEOUT + 1);
        resolver.resetStuckDispute(address(market), MARKET_ID);

        assertEq(resolver.feesAccrued(), FEE * 2, "fees kept");
    }

    function test_resetStuckDispute_rejectsBeforeTheTimeout() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                OptimisticResolver.ArbitrationNotTimedOut.selector, _get().arbitrationDeadline
            )
        );
        resolver.resetStuckDispute(address(market), MARKET_ID);
    }

    function test_resetStuckDispute_allowsAFreshProposal() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        vm.warp(block.timestamp + ARBITRATION_TIMEOUT + 1);
        resolver.resetStuckDispute(address(market), MARKET_ID);

        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 2);
        assertEq(uint8(_get().phase), uint8(OptimisticResolver.Phase.Proposed), "reopened");
    }

    function test_abandonProposal_returnsAStrandedBond() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        uint256 before = usdc.balanceOf(alice);
        vm.warp(block.timestamp + DISPUTE_WINDOW + ARBITRATION_TIMEOUT + 1);
        resolver.abandonProposal(address(market), MARKET_ID);

        assertEq(usdc.balanceOf(alice), before + BOND, "bond back");
        assertEq(uint8(_get().phase), uint8(OptimisticResolver.Phase.None), "cleared");
    }

    function test_abandonProposal_rejectsBeforeTheTimeout() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.expectRevert(
            abi.encodeWithSelector(OptimisticResolver.ProposalNotExpired.selector, _get().arbitrationDeadline)
        );
        resolver.abandonProposal(address(market), MARKET_ID);
    }

    /// @dev The case the backstop exists for: the market got settled some other way, so `finalize`
    ///      would revert forever and the stake would be locked.
    function test_abandonProposal_recoversFromAnUnfinalizableProposal() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        // A second market id on the same mock settles the whole mock, which is what makes the first
        // proposal unfinalizable.
        vm.prank(bob);
        resolver.propose(address(market), 1, 2);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), 1);

        vm.expectRevert(MockOptimisticMarket.AlreadySettled.selector);
        resolver.finalize(address(market), MARKET_ID);

        uint256 before = usdc.balanceOf(alice);
        vm.warp(block.timestamp + ARBITRATION_TIMEOUT + 1);
        resolver.abandonProposal(address(market), MARKET_ID);
        assertEq(usdc.balanceOf(alice), before + BOND, "stake recovered");
    }

    // =====================================================================
    // Degraded engines
    // =====================================================================

    /// @dev The contract with an engine is that a missing or reverting optional view degrades the
    ///      reward and never blocks a settlement. The stake is unaffected: it no longer depends on
    ///      anything the engine has to answer.
    function test_settlesAgainstAnEngineWithoutTheOptionalViews() public {
        market.setViewsBroken(true);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        assertEq(usdc.balanceOf(alice), before - BOND - FEE, "full stake, no engine read needed");

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        assertTrue(market.resolved(), "settled anyway");
        assertEq(usdc.balanceOf(alice), before - FEE, "stake back, no reward");
    }

    // =====================================================================
    // Relay boundary
    // =====================================================================

    /// @dev Two independent locks keep a relayed call away from a privileged path: the forwarder's
    ///      selector allowlist, and this. Only the second one is testable here.
    function test_privilegedPathsRefuseTheForwarder() public {
        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);

        vm.startPrank(forwarder);
        vm.expectRevert(OptimisticResolver.RelayNotAllowed.selector);
        resolver.arbitrate(address(market), MARKET_ID, 2);

        vm.expectRevert(OptimisticResolver.RelayNotAllowed.selector);
        resolver.setParameters(_params());

        vm.expectRevert(OptimisticResolver.RelayNotAllowed.selector);
        resolver.sweepFees(treasury);

        vm.expectRevert(OptimisticResolver.RelayNotAllowed.selector);
        resolver.withdrawRewardPool(treasury, 1);
        vm.stopPrank();
    }

    // =====================================================================
    // Conservation
    // =====================================================================

    /// @dev The single invariant worth stating over the whole lifecycle: the contract's balance is
    ///      always exactly what it owes bonders, plus what it owes the operator in fees, plus the
    ///      reward pool. Nothing else can be hiding in there.
    function test_balanceAlwaysEqualsWhatIsOwed() public {
        _assertConserved();

        vm.prank(alice);
        resolver.propose(address(market), MARKET_ID, 1);
        _assertConserved();

        vm.prank(bob);
        resolver.dispute(address(market), MARKET_ID, 2);
        _assertConserved();

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);
        _assertConserved();

        vm.prank(operator);
        resolver.sweepFees(treasury);
        _assertConserved();
    }

    function _assertConserved() internal view {
        assertEq(
            usdc.balanceOf(address(resolver)),
            resolver.bondedTotal() + resolver.feesAccrued() + resolver.rewardPool(),
            "balance equals bonds + fees + pool"
        );
    }
}

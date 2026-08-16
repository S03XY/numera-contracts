// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketEngine} from "../interfaces/IMarketEngine.sol";
import {TrustedResolver} from "./TrustedResolver.sol";
import {Roles} from "../access/Roles.sol";
import {ZeroAddress} from "../libraries/Errors.sol";

/// @dev The pot, for sizing a proposer's reward. Not on {IMarketEngine} because only this contract
///      needs it, and widening that interface would oblige every future engine to implement it.
interface IMarketPot {
    function collateralOf(uint256 marketId) external view returns (uint256);
}

/// @title PrivateOptimisticResolver
/// @notice Anyone may settle a closed market by staking a bond, without revealing who they are.
///
/// @dev ## The shape
///
/// ```
/// closeTime
///    │
///    ├─ PROPOSE  (any market account, bond) ──► dispute window
///    │     │
///    │     ├─ nobody disputes ──► FINALIZE (anyone): outcome settles,
///    │     │                      proposer takes bond back + reward
///    │     │
///    │     └─ DISPUTE (any market account, equal bond) ──► ARBITRATE (operator)
///    │                 whoever was right takes both bonds + reward
///    │
///    └─ nobody proposes ──► the operator settles directly, no bond, no reward
/// ```
///
/// ## Why the proposer is private, and why that is the hard part
///
/// Whoever proposes an outcome is, overwhelmingly, someone holding it. A proposal from a login
/// wallet publishes "this address probably holds Argentina", which is a link between a public
/// identity and a shielded position. So proposals arrive through {ResolutionForwarder} from the same
/// derived market account that placed the bets, and `_msgSender()` here is that account.
///
/// Anonymity costs the system the deterrent it would normally lean on: a pseudonymous liar cannot be
/// reputationally punished, so **the money has to do all of the work**. That is why the incentives
/// are two-sided rather than a bond alone:
///
///  - being right pays a reward, so watching a market is worth someone's time;
///  - being wrong forfeits the bond **to the other side**, so catching a lie is profitable.
///
/// A false proposal is therefore not merely risky, it is a bounty posted for anyone who disputes it.
/// That is what replaces the watcher network an optimistic system usually assumes.
///
/// ## What this does not claim
///
/// The operator arbitrates, so the operator is still the final word on a contested outcome. This
/// layer exists to take routine settlement off the operator, not to remove trust in them. Traders
/// should read it as: *the operator cannot settle quietly, because anyone can force a public
/// dispute; but the operator does decide.*
///
/// ## Where it sits
///
/// It calls {TrustedResolver} rather than the engine, holding `RESOLVER_ROLE` there. A market's
/// `resolver` is fixed at creation, so routing through the resolver those markets already trust is
/// what lets this govern books that were created before it existed.
contract PrivateOptimisticResolver is AccessControl, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Sentinel outcome meaning "void this market; everyone refunds".
    uint256 public constant INVALID_OUTCOME = type(uint256).max;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Upper bound on the configurable reward rate, so no admin can drain the pool per market.
    uint16 public constant MAX_REWARD_BPS = 500; // 5%

    enum Phase {
        None,
        Proposed,
        Disputed
    }

    struct Proposal {
        address proposer;
        address disputer;
        uint256 outcome;
        uint64 disputeDeadline;
        uint64 arbitrationDeadline;
        /// @dev Snapshot, so changing {bond} never strands or inflates a bond already posted.
        uint128 bondEach;
        Phase phase;
    }

    /// @notice The collateral bonds and rewards are denominated in.
    IERC20 public immutable collateral;

    /// @notice The resolver this contract settles through, holding `RESOLVER_ROLE` on it.
    TrustedResolver public immutable trustedResolver;

    /// @notice What a proposal or a dispute costs to post.
    uint256 public bond;

    /// @notice How long a proposal can be disputed after it is posted.
    uint64 public disputeWindow;

    /// @notice How long the operator has to arbitrate before anyone may unwind the dispute.
    uint64 public arbitrationTimeout;

    /// @notice Share of the market's pot paid to whoever was right, before the cap.
    uint16 public rewardBps;

    /// @notice Hard ceiling on a single reward, whatever the pot.
    uint256 public rewardCap;

    /// @notice Collateral locked as bonds.
    /// @dev Tracked so a reward can never be paid out of somebody's bond. The reward pool is
    ///      `balanceOf(this) - bondedTotal`, and it is funded by the operator out of trading fees —
    ///      never out of the pot, which belongs to the winners at 1:1.
    uint256 public bondedTotal;

    mapping(address market => mapping(uint256 marketId => Proposal)) private _proposals;

    error MarketNotClosed(address market, uint256 marketId);
    error OutcomeOutOfRange(uint256 outcomeId, uint32 outcomeCount);
    error ProposalExists(address market, uint256 marketId);
    error NoProposal(address market, uint256 marketId);
    error NotDisputable(address market, uint256 marketId);
    error DisputeWindowOpen(uint64 deadline);
    error NotDisputed(address market, uint256 marketId);
    error ArbitrationNotTimedOut(uint64 deadline);
    error ProposalNotExpired(uint64 deadline);
    error RewardTooHigh(uint16 provided, uint16 max);
    error WindowZero();
    error InsufficientFreeBalance(uint256 requested, uint256 available);

    event Proposed(
        address indexed market,
        uint256 indexed marketId,
        address indexed proposer,
        uint256 outcome,
        uint256 bond,
        uint64 disputeDeadline
    );
    event Disputed(
        address indexed market,
        uint256 indexed marketId,
        address indexed disputer,
        uint256 bond,
        uint64 arbitrationDeadline
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
        uint256 forfeited,
        uint256 reward
    );
    event ResolvedByOperator(address indexed market, uint256 indexed marketId, uint256 outcome);
    event ProposalAbandoned(address indexed market, uint256 indexed marketId, address indexed proposer);
    event DisputeReset(address indexed market, uint256 indexed marketId);
    event ParametersUpdated(
        uint256 bond, uint64 disputeWindow, uint64 arbitrationTimeout, uint16 rewardBps, uint256 rewardCap
    );
    event RewardPoolWithdrawn(address indexed to, uint256 amount);

    /// @param admin Receives `DEFAULT_ADMIN_ROLE` and `RESOLVER_ROLE`; normally the resolver multisig.
    /// @param forwarder The {ResolutionForwarder} that speaks for market accounts.
    constructor(
        address admin,
        address forwarder,
        address collateral_,
        address trustedResolver_,
        uint256 bond_,
        uint64 disputeWindow_,
        uint64 arbitrationTimeout_,
        uint16 rewardBps_,
        uint256 rewardCap_
    ) ERC2771Context(forwarder) {
        if (admin == address(0) || collateral_ == address(0) || trustedResolver_ == address(0)) {
            revert ZeroAddress();
        }
        collateral = IERC20(collateral_);
        trustedResolver = TrustedResolver(trustedResolver_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.RESOLVER_ROLE, admin);
        _setParameters(bond_, disputeWindow_, arbitrationTimeout_, rewardBps_, rewardCap_);
    }

    // ---------------------------------------------------------------------
    // The optimistic path
    // ---------------------------------------------------------------------

    /// @notice Stake a bond on `outcomeId` being the result of a closed market.
    /// @dev Relayed, so `_msgSender()` is the caller's market account and the proposer stays inside
    ///      the same anonymity set as their trades.
    function propose(address market, uint256 marketId, uint256 outcomeId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.None) revert ProposalExists(market, marketId);
        _assertClosed(market, marketId);
        _assertOutcome(market, marketId, outcomeId);

        address proposer = _msgSender();
        uint256 staked = bond;
        uint64 deadline = uint64(block.timestamp) + disputeWindow;

        p.phase = Phase.Proposed;
        p.proposer = proposer;
        p.outcome = outcomeId;
        p.bondEach = uint128(staked);
        p.disputeDeadline = deadline;
        // Doubles as the abandon deadline: a proposal nobody can finalize must not lock a bond
        // forever, whatever the reason it became unfinalizable.
        p.arbitrationDeadline = deadline + arbitrationTimeout;

        bondedTotal += staked;
        collateral.safeTransferFrom(proposer, address(this), staked);

        emit Proposed(market, marketId, proposer, outcomeId, staked, deadline);
    }

    /// @notice Stake an equal bond that the standing proposal is wrong.
    /// @dev Also relayed: a disputer is usually holding the other side, so they need the same cover.
    function dispute(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Proposed) revert NotDisputable(market, marketId);
        if (block.timestamp > p.disputeDeadline) revert NotDisputable(market, marketId);

        address disputer = _msgSender();
        uint256 staked = p.bondEach;
        uint64 deadline = uint64(block.timestamp) + arbitrationTimeout;

        p.phase = Phase.Disputed;
        p.disputer = disputer;
        p.arbitrationDeadline = deadline;

        bondedTotal += staked;
        collateral.safeTransferFrom(disputer, address(this), staked);

        emit Disputed(market, marketId, disputer, staked, deadline);
    }

    /// @notice Settle an unchallenged proposal once its window has passed.
    /// @dev Permissionless and deliberately not relayable: the reward goes to the recorded proposer
    ///      whoever calls this, so the caller reveals nothing about a position.
    function finalize(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Proposed) revert NoProposal(market, marketId);
        if (block.timestamp <= p.disputeDeadline) revert DisputeWindowOpen(p.disputeDeadline);

        address proposer = p.proposer;
        uint256 outcome = p.outcome;
        uint256 refund = p.bondEach;

        delete _proposals[market][marketId];
        bondedTotal -= refund;

        _settle(market, marketId, outcome);
        uint256 reward = _payout(market, marketId, proposer, refund);

        emit Finalized(market, marketId, outcome, proposer, reward);
    }

    // ---------------------------------------------------------------------
    // The operator's paths
    // ---------------------------------------------------------------------

    /// @notice Rule on a disputed market. The side that was right takes both bonds and the reward.
    /// @param trueOutcomeId The correct outcome, or {INVALID_OUTCOME} to void the market.
    function arbitrate(address market, uint256 marketId, uint256 trueOutcomeId)
        external
        onlyRole(Roles.RESOLVER_ROLE)
        nonReentrant
    {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Disputed) revert NotDisputed(market, marketId);
        _assertOutcome(market, marketId, trueOutcomeId);

        // The proposer is right only if the operator confirms exactly what they proposed. Anything
        // else — including a third outcome neither party named — means the dispute was justified,
        // because the proposal that would otherwise have settled was wrong.
        bool proposerWasRight = trueOutcomeId == p.outcome;
        address winner = proposerWasRight ? p.proposer : p.disputer;
        uint256 each = p.bondEach;

        delete _proposals[market][marketId];
        bondedTotal -= each * 2;

        _settle(market, marketId, trueOutcomeId);
        uint256 reward = _payout(market, marketId, winner, each * 2);

        emit Arbitrated(market, marketId, trueOutcomeId, winner, each, reward);
    }

    /// @notice Settle a market nobody proposed on. No bond required, and no reward paid.
    /// @dev Gated on `Phase.None` so the operator cannot settle out from under a live proposal and
    ///      strand its bond. While a proposal stands, {arbitrate} is the operator's way in.
    function resolveUnproposed(address market, uint256 marketId, uint256 outcomeId)
        external
        onlyRole(Roles.RESOLVER_ROLE)
        nonReentrant
    {
        if (_proposals[market][marketId].phase != Phase.None) revert ProposalExists(market, marketId);
        _assertClosed(market, marketId);
        _assertOutcome(market, marketId, outcomeId);

        _settle(market, marketId, outcomeId);
        emit ResolvedByOperator(market, marketId, outcomeId);
    }

    // ---------------------------------------------------------------------
    // Liveness backstops — permissionless, so no silence can lock a bond forever
    // ---------------------------------------------------------------------

    /// @notice Unwind a dispute the operator never ruled on. Both bonds return; the market reopens.
    /// @dev Without this, an operator who goes quiet freezes two traders' collateral permanently and
    ///      leaves the market unsettleable, since a standing dispute blocks every other path.
    function resetStuckDispute(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Disputed) revert NotDisputed(market, marketId);
        if (block.timestamp <= p.arbitrationDeadline) {
            revert ArbitrationNotTimedOut(p.arbitrationDeadline);
        }

        address proposer = p.proposer;
        address disputer = p.disputer;
        uint256 each = p.bondEach;

        delete _proposals[market][marketId];
        bondedTotal -= each * 2;

        collateral.safeTransfer(proposer, each);
        collateral.safeTransfer(disputer, each);

        emit DisputeReset(market, marketId);
    }

    /// @notice Release a proposal that can no longer be finalized, whatever the cause.
    /// @dev The catch-all. If the market was settled by some other route while a proposal stood,
    ///      {finalize} reverts forever and the bond would be stuck; this returns it once the same
    ///      timeout has passed. No reward: nothing was demonstrably right.
    function abandonProposal(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Proposed) revert NoProposal(market, marketId);
        if (block.timestamp <= p.arbitrationDeadline) revert ProposalNotExpired(p.arbitrationDeadline);

        address proposer = p.proposer;
        uint256 refund = p.bondEach;

        delete _proposals[market][marketId];
        bondedTotal -= refund;
        collateral.safeTransfer(proposer, refund);

        emit ProposalAbandoned(market, marketId, proposer);
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    function setParameters(
        uint256 bond_,
        uint64 disputeWindow_,
        uint64 arbitrationTimeout_,
        uint16 rewardBps_,
        uint256 rewardCap_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParameters(bond_, disputeWindow_, arbitrationTimeout_, rewardBps_, rewardCap_);
    }

    /// @notice Recover unspent reward funding. Bonds are untouchable by construction.
    function withdrawRewardPool(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 free = rewardPool();
        if (amount > free) revert InsufficientFreeBalance(amount, free);
        collateral.safeTransfer(to, amount);
        emit RewardPoolWithdrawn(to, amount);
    }

    function _setParameters(
        uint256 bond_,
        uint64 disputeWindow_,
        uint64 arbitrationTimeout_,
        uint16 rewardBps_,
        uint256 rewardCap_
    ) private {
        if (rewardBps_ > MAX_REWARD_BPS) revert RewardTooHigh(rewardBps_, MAX_REWARD_BPS);
        // A zero window would let a proposal be finalized in the same block it was made, which is
        // no dispute window at all.
        if (disputeWindow_ == 0 || arbitrationTimeout_ == 0) revert WindowZero();

        bond = bond_;
        disputeWindow = disputeWindow_;
        arbitrationTimeout = arbitrationTimeout_;
        rewardBps = rewardBps_;
        rewardCap = rewardCap_;

        emit ParametersUpdated(bond_, disputeWindow_, arbitrationTimeout_, rewardBps_, rewardCap_);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getProposal(address market, uint256 marketId) external view returns (Proposal memory) {
        return _proposals[market][marketId];
    }

    /// @notice Collateral available to pay rewards: everything that is not somebody's bond.
    function rewardPool() public view returns (uint256) {
        uint256 balance = collateral.balanceOf(address(this));
        return balance > bondedTotal ? balance - bondedTotal : 0;
    }

    /// @notice What being right on this market currently pays.
    function rewardFor(address market, uint256 marketId) external view returns (uint256) {
        return _rewardAmount(market, marketId, rewardPool());
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _settle(address market, uint256 marketId, uint256 outcomeId) private {
        if (outcomeId == INVALID_OUTCOME) {
            trustedResolver.invalidateMarket(market, marketId);
        } else {
            trustedResolver.resolveMarket(market, marketId, outcomeId);
        }
    }

    /// @dev Returns `principal` to `winner` and adds the reward, if the pool can cover one.
    ///      Reward sizing runs against the pool AFTER this proposal's bonds have left {bondedTotal},
    ///      so it is measured against genuinely free collateral rather than money about to be repaid.
    function _payout(address market, uint256 marketId, address winner, uint256 principal)
        private
        returns (uint256 reward)
    {
        uint256 balance = collateral.balanceOf(address(this));
        uint256 committed = bondedTotal + principal;
        uint256 free = balance > committed ? balance - committed : 0;

        reward = _rewardAmount(market, marketId, free);
        collateral.safeTransfer(winner, principal + reward);
    }

    function _rewardAmount(address market, uint256 marketId, uint256 available)
        private
        view
        returns (uint256)
    {
        if (rewardBps == 0 || available == 0) return 0;

        // The pot is the only on-chain proxy for what a market earned: trading fees accrue globally
        // per token, not per market. A missing or reverting view simply pays nothing rather than
        // blocking settlement, because a reward is a nicety and a settlement is not.
        uint256 pot;
        try IMarketPot(market).collateralOf(marketId) returns (uint256 held) {
            pot = held;
        } catch {
            return 0;
        }

        uint256 amount = (pot * rewardBps) / BPS_DENOMINATOR;
        if (amount > rewardCap) amount = rewardCap;
        return amount > available ? available : amount;
    }

    function _assertClosed(address market, uint256 marketId) private view {
        if (IMarketEngine(market).closeTimeOf(marketId) > block.timestamp) {
            revert MarketNotClosed(market, marketId);
        }
    }

    function _assertOutcome(address market, uint256 marketId, uint256 outcomeId) private view {
        if (outcomeId == INVALID_OUTCOME) return;
        uint32 count = IMarketEngine(market).outcomeCountOf(marketId);
        if (outcomeId >= count) revert OutcomeOutOfRange(outcomeId, count);
    }

    // ---------------------------------------------------------------------
    // ERC2771Context / Context resolution
    // ---------------------------------------------------------------------

    /// @dev Role checks read `_msgSender()` too, so it matters that the forwarder can only ever
    ///      relay {propose} and {dispute}. Neither is role-gated, so no forwarded call can reach a
    ///      privileged path with a spoofable sender.
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}

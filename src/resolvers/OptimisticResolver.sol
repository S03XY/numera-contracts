// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketEngine} from "../interfaces/IMarketEngine.sol";
import {ITradingBlocklist} from "../interfaces/ITradingBlocklist.sol";
import {TrustedResolver} from "./TrustedResolver.sol";
import {Roles} from "../access/Roles.sol";
import {ZeroAddress} from "../libraries/Errors.sol";

/// @dev The engine reads that shape a reward and guard a stake, but must never block a settlement.
///
///      Deliberately not folded into {IMarketEngine}: that interface is the contract every engine
///      must satisfy, and widening it would retire every engine that predates these two functions.
///      Both are called inside a `try`, so an engine without them settles exactly as well — it
///      simply pays no reward.
interface IResolutionSource {
    function feesOf(uint256 marketId) external view returns (uint256);
    function isSettled(uint256 marketId) external view returns (bool);
}

/// @title OptimisticResolver
/// @notice Anyone may settle a closed market by staking a bond, without revealing who they are.
///         Anyone may dispute the result, including the operator's own. A quorum has the last word.
///
/// @dev ## The shape
///
/// ```
/// closeTime ── trading stops ──┐
///                              │  no deadline to propose: a market waits as long as it needs to
///     ┌────────────────────────┴────────────────────────┐
///     │                                                 │
///  PROPOSE (public)                              PROPOSE (operator or
///  bond + fee, relayed,                          a wallet it trusts)
///  proposer stays private                        no bond, no fee
///     │                                                 │
///     └──────────────────► dispute window ◄─────────────┘
///                    (configurable; both are disputable)
///                                │
///          ┌─────────────────────┴─────────────────────┐
///     nobody disputes                             DISPUTE (bond, relayed)
///          │                                            │
///      FINALIZE (anyone)                          ARBITRATE (multisig)
///      outcome settles;                           whoever was wrong forfeits
///      bonded proposer takes                      the bond AND loses the right
///      bond back + reward                         to trade; whoever was right
///                                                 takes bond back + reward
/// ```
///
/// ## Why the proposer has to be private
///
/// Whoever proposes an outcome is, overwhelmingly, someone holding it. A proposal signed by a login
/// wallet publishes "this address probably holds Argentina", which is a link between a public
/// identity and a shielded position — the exact link the rest of the product exists to prevent. So
/// public proposals and disputes arrive through {ResolutionForwarder} from the same derived market
/// account that placed the bets, and `_msgSender()` here is that account. The proposer never holds
/// gas, and never needs to.
///
/// ## Why the operator does not post a bond
///
/// A bond is collateral against a stranger walking away. The operator cannot walk away: it is the
/// accountable party, it holds the arbitration quorum, and a wrong call by it is answered by the
/// quorum rather than by a forfeit. Requiring it to bond its own markets would be the platform
/// posting collateral to itself. What matters — and what this contract enforces — is that the
/// bond-free path buys **speed, not finality**: an operator proposal opens the same dispute window
/// as anyone else's, and can be overturned by the same quorum.
///
/// ## What being wrong costs
///
/// A bonded party proved wrong loses two things. The bond is forfeited into the reward pool, and the
/// market account is written to {TradingBlocklist} — barred from trading anywhere that reads the
/// list. The forfeit is what makes lying unprofitable; the ban is what stops it being a repeatable
/// business from an account that has already built up a funding path.
///
/// Both apply only to a party that actually staked something. A bond-free operator proposal that the
/// quorum overturns forfeits nothing and bans nobody, because there was no stake and the account is
/// not a market account. That asymmetry is real and is stated rather than hidden.
///
/// ## Where it sits
///
/// It settles through {TrustedResolver} rather than calling the engine, holding `RESOLVER_ROLE`
/// there. A market's `resolver` is immutable from the moment it is created, so routing through the
/// resolver those markets already trust is the only thing that allows this layer to be replaced, or
/// removed, without stranding a single book.
contract OptimisticResolver is AccessControl, ERC2771Context, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Sentinel outcome meaning "void this market; everyone refunds their cost basis".
    /// @dev `type(uint32).max` rather than `type(uint256).max` so a stored outcome packs into the
    ///      same word as its neighbours. Engines report `outcomeCountOf` as a `uint32`, so no real
    ///      outcome can ever collide with it.
    uint256 public constant INVALID_OUTCOME = type(uint32).max;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Ceiling on the configurable reward rate, so no admin can drain the pool per market.
    uint16 public constant MAX_REWARD_BPS = 5_000; // 50% of what the market earned

    enum Phase {
        None,
        Proposed,
        Disputed,
        Settled
    }

    /// @dev Packed to four slots. Fields are ordered for packing, not for reading; the layout is
    ///      `proposer|disputeDeadline|phase|proposerBonded`, `disputer|arbitrationDeadline|outcome`,
    ///      `proposerBond|disputerBond`, `counterOutcome`.
    struct Proposal {
        address proposer;
        uint64 disputeDeadline;
        Phase phase;
        /// @dev False for a `RESOLVER_ROLE` proposal. The authority on whether anything can be
        ///      forfeited, kept explicit rather than inferred from a zero stake — an operator that
        ///      configured {bond} to zero would otherwise be indistinguishable from a bonded party.
        bool proposerBonded;
        address disputer;
        /// @dev Also the abandon deadline while `Proposed`: a proposal nobody can finalize must not
        ///      lock a bond forever, whatever the reason it became unfinalizable.
        uint64 arbitrationDeadline;
        uint32 outcome;
        uint128 proposerBond;
        uint128 disputerBond;
        uint32 counterOutcome;
    }

    /// @dev The outcome of one arbitration, before any of it is acted on. Memory-only.
    struct Ruling {
        address winner;
        address loser;
        uint256 winnerStake;
        uint256 loserStake;
        /// @dev A winner who was right about the *answer*, not merely right to object.
        bool winnerEarnsReward;
        /// @dev False when the losing side never staked anything, which is the bond-free operator.
        bool loserBonded;
    }

    /// @notice The collateral bonds, fees and rewards are denominated in.
    IERC20 public immutable collateral;

    /// @notice The resolver this contract settles through, holding `RESOLVER_ROLE` on it.
    TrustedResolver public immutable trustedResolver;

    /// @notice The shared ban list, or zero to disable banning entirely.
    ITradingBlocklist public immutable blocklist;

    /// @notice What a proposal or a dispute costs to post. The same on every market.
    ///
    /// @dev Flat, deliberately, and this replaced a version that scaled with the market's pot.
    ///      The scaling was justified as sizing the bond against what a liar stands to gain — but
    ///      the gain is the liar's *position*, and positions here are shielded. The pot is a very
    ///      loose upper bound on an invisible number, so the scaling tracked the thing it claimed
    ///      to track only weakly, and the clamp it needed conceded as much.
    ///
    ///      What the bond actually does is deter spam and put skin in the game, and neither of
    ///      those has any reason to grow with the pot. What stops an unchallenged lie is
    ///      {arbitrate} reaching a `Proposed` market, not the size of the stake.
    ///
    ///      The practical gain is that a proposer knows the cost before they open the market.
    uint256 public bond;

    /// @notice Flat, non-refundable charge for using this layer. Not taken from the operator.
    /// @dev Separate from the bond because it is a price, not a stake: it is kept whether or not the
    ///      proposer turns out to be right, and it never enters {bondedTotal}.
    uint256 public proposalFee;

    /// @notice How long a proposal can be disputed after it is posted. Operator-configurable.
    uint64 public disputeWindow;

    /// @notice How long the quorum has to rule before anyone may unwind a dispute.
    uint64 public arbitrationTimeout;

    /// @notice Share of the market's own fee revenue paid to whoever was right, before the cap.
    uint16 public rewardBps;

    /// @notice Hard ceiling on a single reward, whatever the market earned.
    uint256 public rewardCap;

    /// @notice Collateral locked as bonds, owed back to whoever posted it.
    uint256 public bondedTotal;

    /// @notice Collateral taken as {proposalFee}, owed to the operator.
    uint256 public feesAccrued;

    mapping(address market => mapping(uint256 marketId => Proposal)) private _proposals;

    error MarketNotClosed(address market, uint256 marketId);
    error MarketAlreadySettled(address market, uint256 marketId);
    error OutcomeOutOfRange(uint256 outcomeId, uint32 outcomeCount);
    error ProposalExists(address market, uint256 marketId);
    error NoProposal(address market, uint256 marketId);
    error NotDisputable(address market, uint256 marketId);
    error NotArbitrable(address market, uint256 marketId);
    error SameOutcome(uint256 outcomeId);
    error DisputeWindowOpen(uint64 deadline);
    error NotDisputed(address market, uint256 marketId);
    error ArbitrationNotTimedOut(uint64 deadline);
    error ProposalNotExpired(uint64 deadline);
    error RewardTooHigh(uint16 provided, uint16 max);
    error WindowZero();
    error InsufficientFreeBalance(uint256 requested, uint256 available);
    error RelayNotAllowed();

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
    event Disputed(
        address indexed market,
        uint256 indexed marketId,
        address indexed disputer,
        uint256 counterOutcome,
        uint256 bond,
        uint256 fee,
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
        address loser,
        uint256 forfeited,
        uint256 reward
    );
    event Slashed(
        address indexed market, uint256 indexed marketId, address indexed account, uint256 amount, bool banned
    );
    event ProposalAbandoned(address indexed market, uint256 indexed marketId, address indexed proposer);
    event DisputeReset(address indexed market, uint256 indexed marketId);
    event ParametersUpdated(
        uint256 bond,
        uint256 proposalFee,
        uint64 disputeWindow,
        uint64 arbitrationTimeout,
        uint16 rewardBps,
        uint256 rewardCap
    );
    event RewardPoolFunded(address indexed from, uint256 amount);
    event RewardPoolWithdrawn(address indexed to, uint256 amount);
    event FeesSwept(address indexed to, uint256 amount);

    struct Parameters {
        uint256 bond;
        uint256 proposalFee;
        uint64 disputeWindow;
        uint64 arbitrationTimeout;
        uint16 rewardBps;
        uint256 rewardCap;
    }

    /// @param admin Receives `DEFAULT_ADMIN_ROLE` and `RESOLVER_ROLE`: the operator.
    /// @param arbitrator Receives `ARBITRATOR_ROLE`: normally {ResolverMultisig}. Pass the operator
    ///        to run without a quorum, which is a deliberate and visible choice rather than a default.
    /// @param forwarder The {ResolutionForwarder} that speaks for market accounts.
    constructor(
        address admin,
        address arbitrator,
        address forwarder,
        address collateral_,
        address trustedResolver_,
        address blocklist_,
        Parameters memory p
    ) ERC2771Context(forwarder) {
        if (
            admin == address(0) || arbitrator == address(0) || collateral_ == address(0)
                || trustedResolver_ == address(0)
        ) {
            revert ZeroAddress();
        }
        collateral = IERC20(collateral_);
        trustedResolver = TrustedResolver(trustedResolver_);
        blocklist = ITradingBlocklist(blocklist_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.RESOLVER_ROLE, admin);
        _grantRole(Roles.ARBITRATOR_ROLE, arbitrator);
        _setParameters(p);
    }

    /// @dev Marks a path that must never arrive through the forwarder.
    ///
    ///      {AccessControl} resolves its checks through `_msgSender()`, which {ERC2771Context}
    ///      rewrites. The forwarder's selector allowlist already excludes everything privileged, so
    ///      this is the second of two independent locks — worth having, because the cost of the
    ///      first one failing is a stranger arbitrating their own dispute.
    modifier notRelayed() {
        if (isTrustedForwarder(msg.sender)) revert RelayNotAllowed();
        _;
    }

    // ---------------------------------------------------------------------
    // The optimistic path
    // ---------------------------------------------------------------------

    /// @notice Assert `outcomeId` is the result of a closed market, staking a bond unless trusted.
    ///
    /// @dev Relayed for the public path, so `_msgSender()` is the caller's market account and the
    ///      proposer stays inside the same anonymity set as their trades. A `RESOLVER_ROLE` holder
    ///      calling directly skips the bond and the fee, and gains nothing else: the dispute window
    ///      that opens is identical.
    function propose(address market, uint256 marketId, uint256 outcomeId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.None) revert ProposalExists(market, marketId);
        _assertClosed(market, marketId);
        _assertSettleable(market, marketId);
        _assertOutcome(market, marketId, outcomeId);

        address proposer = _msgSender();
        bool trusted = hasRole(Roles.RESOLVER_ROLE, proposer);
        uint256 staked = trusted ? 0 : bond;
        uint256 fee = trusted ? 0 : proposalFee;
        uint64 deadline = uint64(block.timestamp) + disputeWindow;

        p.phase = Phase.Proposed;
        p.proposer = proposer;
        p.proposerBonded = !trusted;
        p.outcome = uint32(outcomeId);
        p.proposerBond = uint128(staked);
        p.disputeDeadline = deadline;
        p.arbitrationDeadline = deadline + arbitrationTimeout;

        if (staked + fee != 0) {
            bondedTotal += staked;
            feesAccrued += fee;
            collateral.safeTransferFrom(proposer, address(this), staked + fee);
        }

        emit Proposed(market, marketId, proposer, outcomeId, staked, fee, !trusted, deadline);
    }

    /// @notice Stake a bond that the standing proposal is wrong, naming what should have been said.
    ///
    /// @dev Also relayed: a disputer is usually holding the other side, so they need the same cover
    ///      as the proposer. The counter-outcome is required rather than optional because it is what
    ///      lets arbitration tell "right to object" apart from "right about the answer", and pay only
    ///      the second one a reward.
    ///
    ///      The bond is always posted, including against a bond-free operator proposal — otherwise
    ///      disputing the operator would be free, and a free action that suspends settlement is a
    ///      denial-of-service primitive.
    function dispute(address market, uint256 marketId, uint256 counterOutcomeId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Proposed) revert NotDisputable(market, marketId);
        if (block.timestamp > p.disputeDeadline) revert NotDisputable(market, marketId);
        if (counterOutcomeId == p.outcome) revert SameOutcome(counterOutcomeId);
        _assertOutcome(market, marketId, counterOutcomeId);

        address disputer = _msgSender();
        // Matched against the proposer's stake where there is one, so neither side can be outspent.
        // Priced afresh only when the proposal was bond-free, since there is nothing to match.
        uint256 staked = p.proposerBonded ? p.proposerBond : bond;
        uint256 fee = proposalFee;
        uint64 deadline = uint64(block.timestamp) + arbitrationTimeout;

        p.phase = Phase.Disputed;
        p.disputer = disputer;
        p.counterOutcome = uint32(counterOutcomeId);
        p.disputerBond = uint128(staked);
        p.arbitrationDeadline = deadline;

        if (staked + fee != 0) {
            bondedTotal += staked;
            feesAccrued += fee;
            collateral.safeTransferFrom(disputer, address(this), staked + fee);
        }

        emit Disputed(market, marketId, disputer, counterOutcomeId, staked, fee, deadline);
    }

    /// @notice Settle an unchallenged proposal once its window has passed.
    ///
    /// @dev Permissionless and deliberately not relayable: the reward goes to the recorded proposer
    ///      whoever calls this, so the caller is not the beneficiary and reveals nothing by calling.
    function finalize(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Proposed) revert NoProposal(market, marketId);
        if (block.timestamp <= p.disputeDeadline) revert DisputeWindowOpen(p.disputeDeadline);

        address proposer = p.proposer;
        uint256 outcome = p.outcome;
        uint256 refund = p.proposerBonded ? p.proposerBond : 0;

        p.phase = Phase.Settled;
        bondedTotal -= refund;

        _settle(market, marketId, outcome);
        // Nothing was staked, so nothing is owed: a trusted wallet is paid in the ordinary course of
        // running the platform, not per settlement.
        uint256 reward = p.proposerBonded ? _payout(market, marketId, proposer, refund) : 0;

        emit Finalized(market, marketId, outcome, proposer, reward);
    }

    // ---------------------------------------------------------------------
    // The quorum's path
    // ---------------------------------------------------------------------

    /// @notice Rule on a market, settling it and resolving both stakes. The final word.
    ///
    /// @dev Reachable from `Disputed` — the ordinary case — and from `Proposed`, which is the
    ///      operator's way to correct its own mistake, or anyone's, that nobody happened to notice.
    ///      That second path is not a loophole bolted on: without it a wrong proposal that draws no
    ///      dispute settles wrongly and permanently, and the quorum's authority would be conditional
    ///      on a stranger having been paying attention.
    ///
    ///      The party that staked on a false outcome forfeits the bond into the reward pool and is
    ///      barred from trading. The party that was right takes its own stake back plus the reward —
    ///      it does not take the loser's bond, which goes to the platform.
    ///
    /// @param trueOutcomeId The correct outcome, or {INVALID_OUTCOME} to void the market.
    function arbitrate(address market, uint256 marketId, uint256 trueOutcomeId)
        external
        notRelayed
        onlyRole(Roles.ARBITRATOR_ROLE)
        nonReentrant
    {
        Proposal storage p = _proposals[market][marketId];
        Phase phase = p.phase;
        if (phase != Phase.Disputed && phase != Phase.Proposed) revert NotArbitrable(market, marketId);
        _assertOutcome(market, marketId, trueOutcomeId);

        Ruling memory r = _ruleOn(p, phase == Phase.Disputed, trueOutcomeId);

        p.phase = Phase.Settled;
        // Both stakes leave the bonded ledger. The winner's is about to be returned; the loser's
        // stays behind and becomes reward pool, which is what "the money is taken" means here.
        bondedTotal -= (r.winnerStake + r.loserStake);

        _settle(market, marketId, trueOutcomeId);

        uint256 reward;
        if (r.winner != address(0)) {
            reward = r.winnerEarnsReward
                ? _payout(market, marketId, r.winner, r.winnerStake)
                : _repay(r.winner, r.winnerStake);
        }
        if (r.loserBonded && r.loser != address(0)) {
            _slashAndBan(market, marketId, r.loser, r.loserStake);
        }

        emit Arbitrated(market, marketId, trueOutcomeId, r.winner, r.loser, r.loserStake, reward);
    }

    /// @dev Who won, who lost, and what each of them staked. Pure decision, no effects.
    ///
    ///      Split out of {arbitrate} for stack room, but it earns its own name anyway: this is the
    ///      whole ruling, in one place, readable without the settlement mechanics around it.
    function _ruleOn(Proposal storage p, bool contested, uint256 trueOutcomeId)
        private
        view
        returns (Ruling memory r)
    {
        // The proposer is right only if the quorum confirms exactly what they proposed. Anything
        // else — including a third outcome neither side named — means the dispute was justified,
        // because the proposal that would otherwise have settled was wrong.
        if (trueOutcomeId == p.outcome) {
            r.winner = p.proposer;
            r.winnerStake = p.proposerBond;
            r.winnerEarnsReward = p.proposerBonded;
            if (contested) {
                r.loser = p.disputer;
                r.loserStake = p.disputerBond;
                r.loserBonded = true;
            }
        } else {
            r.loser = p.proposer;
            r.loserStake = p.proposerBonded ? p.proposerBond : 0;
            r.loserBonded = p.proposerBonded;
            if (contested) {
                r.winner = p.disputer;
                r.winnerStake = p.disputerBond;
                // A disputer who was right to object but wrong about the answer keeps their stake
                // and is not banned — they did the job the bond exists to pay for — but they are not
                // paid for an answer they did not get right.
                r.winnerEarnsReward = trueOutcomeId == p.counterOutcome;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Liveness backstops — permissionless, so no silence can lock a bond forever
    // ---------------------------------------------------------------------

    /// @notice Unwind a dispute the quorum never ruled on. Both bonds return; the market reopens.
    ///
    /// @dev Without this, a quorum that goes quiet freezes two traders' collateral permanently and
    ///      leaves the market unsettleable, since a standing dispute blocks every other path. The
    ///      fees are not returned: the service was used.
    function resetStuckDispute(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Disputed) revert NotDisputed(market, marketId);
        if (block.timestamp <= p.arbitrationDeadline) {
            revert ArbitrationNotTimedOut(p.arbitrationDeadline);
        }

        address proposer = p.proposer;
        address disputer = p.disputer;
        uint256 proposerStake = p.proposerBonded ? p.proposerBond : 0;
        uint256 disputerStake = p.disputerBond;

        delete _proposals[market][marketId];
        bondedTotal -= (proposerStake + disputerStake);

        if (proposerStake != 0) collateral.safeTransfer(proposer, proposerStake);
        if (disputerStake != 0) collateral.safeTransfer(disputer, disputerStake);

        emit DisputeReset(market, marketId);
    }

    /// @notice Release a proposal that can no longer be finalized, whatever the cause.
    ///
    /// @dev The catch-all. If the market was settled by some other route while a proposal stood,
    ///      {finalize} reverts forever and the bond would be stuck; this returns it once the same
    ///      timeout has passed. No reward: nothing was demonstrably right.
    function abandonProposal(address market, uint256 marketId) external nonReentrant {
        Proposal storage p = _proposals[market][marketId];
        if (p.phase != Phase.Proposed) revert NoProposal(market, marketId);
        if (block.timestamp <= p.arbitrationDeadline) revert ProposalNotExpired(p.arbitrationDeadline);

        address proposer = p.proposer;
        uint256 refund = p.proposerBonded ? p.proposerBond : 0;

        delete _proposals[market][marketId];
        bondedTotal -= refund;
        if (refund != 0) collateral.safeTransfer(proposer, refund);

        emit ProposalAbandoned(market, marketId, proposer);
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    function setParameters(Parameters calldata p) external notRelayed onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParameters(p);
    }

    /// @notice Add collateral the rewards are paid from.
    /// @dev A plain transfer would work identically. This exists so funding is a legible on-chain
    ///      event rather than an unexplained balance change.
    function fundRewardPool(uint256 amount) external nonReentrant {
        collateral.safeTransferFrom(_msgSender(), address(this), amount);
        emit RewardPoolFunded(_msgSender(), amount);
    }

    /// @notice Recover unspent reward funding. Bonds and fees are excluded by construction.
    function withdrawRewardPool(address to, uint256 amount)
        external
        notRelayed
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 free = rewardPool();
        if (amount > free) revert InsufficientFreeBalance(amount, free);
        collateral.safeTransfer(to, amount);
        emit RewardPoolWithdrawn(to, amount);
    }

    /// @notice Collect the accumulated {proposalFee} charges.
    function sweepFees(address to) external notRelayed onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = feesAccrued;
        feesAccrued = 0;
        if (amount != 0) collateral.safeTransfer(to, amount);
        emit FeesSwept(to, amount);
    }

    function _setParameters(Parameters memory p) private {
        if (p.rewardBps > MAX_REWARD_BPS) revert RewardTooHigh(p.rewardBps, MAX_REWARD_BPS);
        // A zero window would let a proposal be finalized in the block it was made, which is no
        // dispute window at all.
        if (p.disputeWindow == 0 || p.arbitrationTimeout == 0) revert WindowZero();

        bond = p.bond;
        proposalFee = p.proposalFee;
        disputeWindow = p.disputeWindow;
        arbitrationTimeout = p.arbitrationTimeout;
        rewardBps = p.rewardBps;
        rewardCap = p.rewardCap;

        emit ParametersUpdated(
            p.bond, p.proposalFee, p.disputeWindow, p.arbitrationTimeout, p.rewardBps, p.rewardCap
        );
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getProposal(address market, uint256 marketId) external view returns (Proposal memory) {
        return _proposals[market][marketId];
    }

    /// @notice Collateral available to pay rewards: everything that is nobody's bond and no fee.
    function rewardPool() public view returns (uint256) {
        uint256 balance = collateral.balanceOf(address(this));
        uint256 committed = bondedTotal + feesAccrued;
        return balance > committed ? balance - committed : 0;
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

    /// @dev Return a stake with no reward attached.
    function _repay(address to, uint256 principal) private returns (uint256) {
        if (principal != 0) collateral.safeTransfer(to, principal);
        return 0;
    }

    /// @dev Return `principal` and add the reward, if the pool can cover one.
    ///
    ///      Reward sizing runs against the pool AFTER this proposal's stakes have left
    ///      {bondedTotal}, so `principal` is added back to the committed figure by hand. Without
    ///      that, money that is about to be repaid would read as free and could be paid out twice.
    function _payout(address market, uint256 marketId, address winner, uint256 principal)
        private
        returns (uint256 reward)
    {
        uint256 balance = collateral.balanceOf(address(this));
        uint256 committed = bondedTotal + feesAccrued + principal;
        uint256 free = balance > committed ? balance - committed : 0;

        reward = _rewardAmount(market, marketId, free);
        uint256 total = principal + reward;
        if (total != 0) collateral.safeTransfer(winner, total);
    }

    /// @dev Keep the forfeited stake and bar the account. Neither step may block a settlement, which
    ///      has already happened by the time this runs: the ban is wrapped because the list can
    ///      legitimately refuse — the account may already be barred from an earlier market, or this
    ///      contract may have had `BLOCKLIST_ROLE` revoked — and none of that should strand a market.
    function _slashAndBan(address market, uint256 marketId, address loser, uint256 amount) private {
        bool banned;
        if (address(blocklist) != address(0)) {
            try blocklist.ban(loser, market, marketId) {
                banned = true;
            } catch {}
        }
        emit Slashed(market, marketId, loser, amount, banned);
    }

    function _rewardAmount(address market, uint256 marketId, uint256 available)
        private
        view
        returns (uint256)
    {
        if (rewardBps == 0 || available == 0) return 0;

        // The market's own fee take, which is what "a share of the revenue this market generated"
        // means. A missing or reverting view pays nothing rather than blocking settlement, because a
        // reward is a nicety and a settlement is not.
        uint256 revenue;
        try IResolutionSource(market).feesOf(marketId) returns (uint256 earned) {
            revenue = earned;
        } catch {
            return 0;
        }

        uint256 amount = (revenue * rewardBps) / BPS_DENOMINATOR;
        if (amount > rewardCap) amount = rewardCap;
        return amount > available ? available : amount;
    }

    function _assertClosed(address market, uint256 marketId) private view {
        if (IMarketEngine(market).closeTimeOf(marketId) > block.timestamp) {
            revert MarketNotClosed(market, marketId);
        }
    }

    /// @dev Refuse a bond on a market that is already settled and could never be settled again.
    ///      An engine that cannot answer is given the benefit of the doubt: {abandonProposal} is the
    ///      backstop for the case this check exists to make rare.
    function _assertSettleable(address market, uint256 marketId) private view {
        try IResolutionSource(market).isSettled(marketId) returns (bool settled) {
            if (settled) revert MarketAlreadySettled(market, marketId);
        } catch {}
    }

    function _assertOutcome(address market, uint256 marketId, uint256 outcomeId) private view {
        if (outcomeId == INVALID_OUTCOME) return;
        uint32 count = IMarketEngine(market).outcomeCountOf(marketId);
        if (outcomeId >= count) revert OutcomeOutOfRange(outcomeId, count);
    }

    // ---------------------------------------------------------------------
    // ERC2771Context / Context resolution
    // ---------------------------------------------------------------------

    /// @dev Role checks read `_msgSender()` too. Two things keep that safe: the forwarder relays
    ///      only {propose} and {dispute}, and every privileged path here carries {notRelayed}. The
    ///      role read inside {propose} is intentional — an operator wallet signing a meta-transaction
    ///      is still that wallet, because the forwarder verified its signature.
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

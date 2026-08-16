// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {Constants} from "../libraries/Constants.sol";
import {MarketTypes} from "../libraries/MarketTypes.sol";
import {ParimutuelMath} from "../libraries/ParimutuelMath.sol";
import {Roles} from "../access/Roles.sol";
import {IResolvableMarket} from "../interfaces/IResolvableMarket.sol";
import {
    ZeroAddress,
    InvalidOutcomeCount,
    FeeTooHigh,
    CloseTimeInPast,
    MarketNotFound,
    MarketNotTrading,
    MarketClosed,
    MarketNotClosed,
    MarketNotResolved,
    MarketNotInvalid,
    InvalidOutcome,
    AmountZero,
    AmountBelowMin,
    NothingToClaim,
    AlreadyClaimed,
    NotResolver
} from "../libraries/Errors.sol";

/// @title ParimutuelMarket
/// @notice A pooled (parimutuel) prediction-market engine hosting many markets in one contract.
///         Supports binary (Yes/No) and multi-outcome (up to 256) markets for any category.
///
/// @dev Privacy / Unlink integration model (see ARCHITECTURE.md):
///      - Users interact exclusively through Unlink's `execute()`, so `msg.sender` here is an
///        ephemeral, unlinkable ERC-4337 ExecutionAccount — never the real trader. Positions are
///        therefore keyed by `msg.sender`. This contract NEVER reads `tx.origin` (which would be
///        Unlink's bundler) and never assumes the caller holds native gas (gas is paymaster-sponsored).
///      - Collateral is a per-market ERC-20 (USDC by default), matching Unlink's ERC-20-only flows.
///      - Winnings are paid to `msg.sender`, so an ExecutionAccount can sweep them back into the
///        shielded pool via `returnToPool` in the same UserOperation.
///      Market data (pools, prices, totals) is fully public; only the trader identity is hidden,
///      and that hiding is delegated to Unlink's shielded pool.
///
///      Fairness: all market parameters are fixed at creation and immutable thereafter, so operators
///      cannot alter fees/close-time/outcomes after bettors have committed funds.
contract ParimutuelMarket is IResolvableMarket, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ParimutuelMath for uint256;

    /// @notice Why a market was voided.
    enum InvalidReason {
        Manual, // resolver explicitly invalidated (e.g. event cancelled)
        NoWinners // resolved to an outcome nobody staked -> auto-voided to avoid stuck funds
    }

    /// @notice Parameters for creating a market. Every field is caller-configurable.
    struct CreateParams {
        address collateral; // ERC-20 collateral (e.g. USDC)
        address resolver; // the only address allowed to resolve/invalidate this market
        uint64 closeTime; // betting allowed while block.timestamp < closeTime
        uint32 outcomeCount; // number of outcomes (2..256); 2 == binary Yes/No
        uint16 feeBps; // protocol fee on the pot at resolution (<= MAX_FEE_BPS)
        uint256 minBet; // minimum stake per bet, in collateral base units
        bytes32 category; // free-form category tag (e.g. "SPORTS", "POLITICS")
        bytes32 metadataHash; // pointer/hash to off-chain details (question, outcome labels)
    }

    /// @dev Full on-chain state of one market. Contains mappings, so it lives only in storage.
    struct Market {
        // ---- immutable config ----
        address collateral;
        address resolver;
        uint64 closeTime;
        uint32 outcomeCount;
        uint16 feeBps;
        uint256 minBet;
        bytes32 category;
        bytes32 metadataHash;
        // ---- mutable state ----
        MarketTypes.Status status;
        uint32 winningOutcomeId;
        uint256 totalPool; // sum of all outcome pools
        uint256 netPot; // distributable pot after fee, cached at resolution
        uint256 feeCollected; // protocol fee skimmed at resolution
        // ---- ledgers ----
        mapping(uint256 => uint256) outcomePool; // outcomeId => staked collateral
        mapping(address => mapping(uint256 => uint256)) stakeOf; // owner => outcomeId => stake
        mapping(address => uint256) totalStakeOf; // owner => total stake across outcomes
        mapping(address => bool) claimed; // owner => claimed/refunded already
    }

    /// @notice Mapping-free projection of a market, returned by {getMarket}.
    struct MarketView {
        address collateral;
        address resolver;
        uint64 closeTime;
        uint32 outcomeCount;
        uint16 feeBps;
        MarketTypes.Status status;
        uint32 winningOutcomeId;
        uint256 minBet;
        bytes32 category;
        bytes32 metadataHash;
        uint256 totalPool;
        uint256 netPot;
        uint256 feeCollected;
        bool bettingOpen; // status==Trading && block.timestamp < closeTime
    }

    /// @notice Number of markets ever created; also the id of the next market.
    uint256 public marketCount;

    /// @dev marketId => market.
    mapping(uint256 => Market) internal markets;

    /// @notice Protocol fees accrued per collateral token, pending withdrawal.
    mapping(address => uint256) public accruedFees;

    // -------------------------------------------------------------------------
    // Events (market data is public; the `account` is the unlinkable ExecutionAccount)
    // -------------------------------------------------------------------------

    event MarketCreated(
        uint256 indexed marketId,
        address indexed collateral,
        address resolver,
        uint64 closeTime,
        uint32 outcomeCount,
        uint16 feeBps,
        uint256 minBet,
        bytes32 category,
        bytes32 metadataHash,
        address creator
    );
    event BetPlaced(
        uint256 indexed marketId,
        address indexed account,
        uint256 indexed outcomeId,
        uint256 amount,
        uint256 newOutcomePool,
        uint256 newTotalPool
    );
    event MarketResolved(uint256 indexed marketId, uint32 winningOutcomeId, uint256 netPot, uint256 fee);
    event MarketInvalidated(uint256 indexed marketId, InvalidReason reason);
    event Claimed(uint256 indexed marketId, address indexed account, uint256 payout);
    event Refunded(uint256 indexed marketId, address indexed account, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @param admin Receives DEFAULT_ADMIN_ROLE plus the operational roles at deploy.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.MARKET_CREATOR_ROLE, admin);
        _grantRole(Roles.PAUSER_ROLE, admin);
        _grantRole(Roles.FEE_MANAGER_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Market creation
    // -------------------------------------------------------------------------

    /// @notice Create a new market. Permissioned by MARKET_CREATOR_ROLE (grant widely to open it up).
    /// @param p Fully-configurable market parameters.
    /// @return marketId The id of the newly created market.
    function createMarket(CreateParams calldata p)
        external
        onlyRole(Roles.MARKET_CREATOR_ROLE)
        returns (uint256 marketId)
    {
        if (p.collateral == address(0) || p.resolver == address(0)) {
            revert ZeroAddress();
        }
        if (p.outcomeCount < Constants.MIN_OUTCOMES || p.outcomeCount > Constants.MAX_OUTCOMES) {
            revert InvalidOutcomeCount(p.outcomeCount, Constants.MIN_OUTCOMES, Constants.MAX_OUTCOMES);
        }
        if (p.feeBps > Constants.MAX_FEE_BPS) revert FeeTooHigh(p.feeBps, Constants.MAX_FEE_BPS);
        if (p.closeTime <= block.timestamp) revert CloseTimeInPast(p.closeTime, uint64(block.timestamp));

        marketId = marketCount++;
        Market storage m = markets[marketId];
        m.collateral = p.collateral;
        m.resolver = p.resolver;
        m.closeTime = p.closeTime;
        m.outcomeCount = p.outcomeCount;
        m.feeBps = p.feeBps;
        m.minBet = p.minBet;
        m.category = p.category;
        m.metadataHash = p.metadataHash;
        // status defaults to Trading (enum value 0).

        emit MarketCreated(
            marketId,
            p.collateral,
            p.resolver,
            p.closeTime,
            p.outcomeCount,
            p.feeBps,
            p.minBet,
            p.category,
            p.metadataHash,
            msg.sender
        );
    }

    // -------------------------------------------------------------------------
    // Betting
    // -------------------------------------------------------------------------

    /// @notice Stake `amount` of collateral on `outcomeId` of `marketId`.
    /// @dev Credits the *actually received* amount (balance-delta), so fee-on-transfer tokens are
    ///      accounted correctly. The position is recorded against `msg.sender` (the ExecutionAccount).
    /// @param marketId Target market.
    /// @param outcomeId Chosen outcome (0-indexed).
    /// @param amount Collateral to stake, in base units.
    /// @return credited The amount actually credited to the position.
    function placeBet(uint256 marketId, uint256 outcomeId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 credited)
    {
        Market storage m = _get(marketId);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        if (block.timestamp >= m.closeTime) revert MarketClosed(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        if (amount == 0) revert AmountZero();

        IERC20 token = IERC20(m.collateral);
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        credited = token.balanceOf(address(this)) - balBefore;

        if (credited < m.minBet || credited == 0) revert AmountBelowMin(credited, m.minBet);

        uint256 newOutcomePool = m.outcomePool[outcomeId] + credited;
        m.outcomePool[outcomeId] = newOutcomePool;
        m.totalPool += credited;
        m.stakeOf[msg.sender][outcomeId] += credited;
        m.totalStakeOf[msg.sender] += credited;

        emit BetPlaced(marketId, msg.sender, outcomeId, credited, newOutcomePool, m.totalPool);
    }

    // -------------------------------------------------------------------------
    // Resolution (restricted to the market's bound resolver)
    // -------------------------------------------------------------------------

    /// @inheritdoc IResolvableMarket
    /// @dev Requires betting to have closed. If the winning outcome has zero stake, the market is
    ///      auto-voided (refunds) instead of resolved, so funds are never stranded.
    function resolve(uint256 marketId, uint256 winningOutcomeId) external {
        Market storage m = _get(marketId);
        if (msg.sender != m.resolver) revert NotResolver(msg.sender);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        if (block.timestamp < m.closeTime) revert MarketNotClosed(marketId);
        if (winningOutcomeId >= m.outcomeCount) revert InvalidOutcome(winningOutcomeId, m.outcomeCount);

        if (m.outcomePool[winningOutcomeId] == 0) {
            // Nobody predicted the winner -> void the market so everyone can refund.
            m.status = MarketTypes.Status.Invalid;
            emit MarketInvalidated(marketId, InvalidReason.NoWinners);
            return;
        }

        uint256 fee = ParimutuelMath.protocolFee(m.totalPool, m.feeBps);
        m.feeCollected = fee;
        m.netPot = m.totalPool - fee;
        m.winningOutcomeId = uint32(winningOutcomeId);
        m.status = MarketTypes.Status.Resolved;
        accruedFees[m.collateral] += fee;

        emit MarketResolved(marketId, uint32(winningOutcomeId), m.netPot, fee);
    }

    /// @inheritdoc IResolvableMarket
    /// @dev Voids a market from the Trading state (e.g. the underlying event was cancelled),
    ///      enabling full refunds. No fee is taken on invalidation.
    function invalidate(uint256 marketId) external {
        Market storage m = _get(marketId);
        if (msg.sender != m.resolver) revert NotResolver(msg.sender);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);

        m.status = MarketTypes.Status.Invalid;
        emit MarketInvalidated(marketId, InvalidReason.Manual);
    }

    // -------------------------------------------------------------------------
    // Claiming & refunding (paid to msg.sender -> sweepable back into the shielded pool)
    // -------------------------------------------------------------------------

    /// @notice Claim winnings from a resolved market for the caller's winning stake.
    /// @dev Pays `msg.sender`. Reverts if the caller had no winning stake or already claimed.
    function claim(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = _get(marketId);
        if (m.status != MarketTypes.Status.Resolved) revert MarketNotResolved(marketId);
        if (m.claimed[msg.sender]) revert AlreadyClaimed();

        uint256 winStake = m.stakeOf[msg.sender][m.winningOutcomeId];
        payout = ParimutuelMath.winnerPayout(winStake, m.outcomePool[m.winningOutcomeId], m.netPot);
        if (payout == 0) revert NothingToClaim();

        m.claimed[msg.sender] = true; // effects before interaction (CEI)
        IERC20(m.collateral).safeTransfer(msg.sender, payout);

        emit Claimed(marketId, msg.sender, payout);
    }

    /// @notice Refund the caller's full stake from an invalidated market.
    /// @dev Pays `msg.sender`. Reverts if the caller had no stake or already refunded.
    function refund(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _get(marketId);
        if (m.status != MarketTypes.Status.Invalid) revert MarketNotInvalid(marketId);
        if (m.claimed[msg.sender]) revert AlreadyClaimed();

        amount = m.totalStakeOf[msg.sender];
        if (amount == 0) revert NothingToClaim();

        m.claimed[msg.sender] = true; // effects before interaction (CEI)
        IERC20(m.collateral).safeTransfer(msg.sender, amount);

        emit Refunded(marketId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Protocol fees
    // -------------------------------------------------------------------------

    /// @notice Withdraw accrued protocol fees for `token` to `to`. Restricted to FEE_MANAGER_ROLE.
    function withdrawFees(address token, address to, uint256 amount)
        external
        onlyRole(Roles.FEE_MANAGER_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 accrued = accruedFees[token];
        if (amount == 0 || amount > accrued) revert AmountBelowMin(amount, 1);
        accruedFees[token] = accrued - amount;
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // Emergency pause (betting only; exits are always allowed)
    // -------------------------------------------------------------------------

    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Views — public market data & prices
    // -------------------------------------------------------------------------

    /// @notice Full projection of a market's config and state.
    function getMarket(uint256 marketId) external view returns (MarketView memory v) {
        Market storage m = _get(marketId);
        v = MarketView({
            collateral: m.collateral,
            resolver: m.resolver,
            closeTime: m.closeTime,
            outcomeCount: m.outcomeCount,
            feeBps: m.feeBps,
            status: m.status,
            winningOutcomeId: m.winningOutcomeId,
            minBet: m.minBet,
            category: m.category,
            metadataHash: m.metadataHash,
            totalPool: m.totalPool,
            netPot: m.netPot,
            feeCollected: m.feeCollected,
            bettingOpen: m.status == MarketTypes.Status.Trading && block.timestamp < m.closeTime
        });
    }

    /// @notice Betting close time of a market (engine-agnostic getter used by resolvers).
    function closeTimeOf(uint256 marketId) external view returns (uint64) {
        return _get(marketId).closeTime;
    }

    /// @notice Number of outcomes of a market (engine-agnostic getter used by resolvers).
    function outcomeCountOf(uint256 marketId) external view returns (uint32) {
        return _get(marketId).outcomeCount;
    }

    /// @notice Collateral staked on a single outcome.
    function outcomePool(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        return _get(marketId).outcomePool[outcomeId];
    }

    /// @notice Every outcome's pool, indexed by outcomeId.
    function getOutcomePools(uint256 marketId) external view returns (uint256[] memory pools) {
        Market storage m = _get(marketId);
        pools = new uint256[](m.outcomeCount);
        for (uint256 i; i < m.outcomeCount; ++i) {
            pools[i] = m.outcomePool[i];
        }
    }

    /// @notice Implied probability (price) of an outcome, in WAD (1e18 == 100%).
    function priceWad(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        Market storage m = _get(marketId);
        return ParimutuelMath.priceWad(m.outcomePool[outcomeId], m.totalPool);
    }

    /// @notice Implied prices for all outcomes, in WAD. Sums to ~1e18.
    function getPrices(uint256 marketId) external view returns (uint256[] memory prices) {
        Market storage m = _get(marketId);
        prices = new uint256[](m.outcomeCount);
        uint256 total = m.totalPool;
        for (uint256 i; i < m.outcomeCount; ++i) {
            prices[i] = ParimutuelMath.priceWad(m.outcomePool[i], total);
        }
    }

    /// @notice Live decimal odds of an outcome, in WAD (e.g. 2.5x == 2.5e18).
    /// @dev Uses the fee-adjusted pot so it reflects the true return if the outcome wins now.
    function oddsWad(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        Market storage m = _get(marketId);
        uint256 pot = ParimutuelMath.netPool(m.totalPool, m.feeBps);
        return ParimutuelMath.oddsWad(m.outcomePool[outcomeId], pot);
    }

    /// @notice Caller's (account's) stake on a specific outcome.
    function stakeOf(uint256 marketId, address account, uint256 outcomeId) external view returns (uint256) {
        return _get(marketId).stakeOf[account][outcomeId];
    }

    /// @notice Account's total stake across all outcomes.
    function totalStakeOf(uint256 marketId, address account) external view returns (uint256) {
        return _get(marketId).totalStakeOf[account];
    }

    /// @notice Whether an account has already claimed or refunded in this market.
    function isClaimed(uint256 marketId, address account) external view returns (bool) {
        return _get(marketId).claimed[account];
    }

    /// @notice How much `account` could claim/refund right now (0 if nothing or already claimed).
    function claimable(uint256 marketId, address account) external view returns (uint256) {
        Market storage m = _get(marketId);
        if (m.claimed[account]) return 0;
        if (m.status == MarketTypes.Status.Resolved) {
            return ParimutuelMath.winnerPayout(
                m.stakeOf[account][m.winningOutcomeId], m.outcomePool[m.winningOutcomeId], m.netPot
            );
        }
        if (m.status == MarketTypes.Status.Invalid) {
            return m.totalStakeOf[account];
        }
        return 0;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _get(uint256 marketId) internal view returns (Market storage m) {
        if (marketId >= marketCount) revert MarketNotFound(marketId);
        m = markets[marketId];
    }
}

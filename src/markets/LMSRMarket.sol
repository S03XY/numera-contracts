// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {Constants} from "../libraries/Constants.sol";
import {MarketTypes} from "../libraries/MarketTypes.sol";
import {LMSRMath} from "../libraries/LMSRMath.sol";
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
    InvalidOutcome,
    AmountZero,
    AmountBelowMin,
    NothingToClaim,
    AlreadyClaimed,
    NotResolver,
    NotAuthorized,
    SlippageExceeded,
    InsufficientShares,
    ZeroLiquidity,
    LiquidityTooHigh,
    AmountTooLarge
} from "../libraries/Errors.sol";

/// @title LMSRMarket
/// @notice A Logarithmic Market Scoring Rule (LMSR) prediction-market engine hosting many markets.
///         Every trade continuously shifts the public prices; supports binary (Yes/No) and
///         multi-outcome markets for any category.
///
/// @dev Pricing & solvency:
///      - The maker holds exactly `C(q)` collateral at all times (see {LMSRMath}). It is seeded at
///        creation with the bounded-loss subsidy `C(0) = b*ln(N)`, so `pot == C(q)` thereafter.
///      - Buying outcome `i` raises `q_i`, raising its public price `p_i` — this is the visible
///        price shift. Prices always sum to 1 and are exposed via {prices}/{priceWad}.
///      - Because `C(q) >= q_i` for every outcome, the winning shares (`q_winner`) are always fully
///        covered; the remainder (`pot - q_winner`) is the liquidity provider's settlement.
///
///      Privacy / Unlink model (identical to {ParimutuelMarket}): users trade through Unlink
///      `execute()`, so `msg.sender` is an ephemeral, unlinkable ExecutionAccount. No `tx.origin`,
///      no native-gas assumptions, ERC-20 (USDC) collateral, proceeds paid to `msg.sender` for
///      sweeping back into the shielded pool. Prices are public; the trader is not.
contract LMSRMarket is IResolvableMarket, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fully-configurable parameters for creating an LMSR market.
    struct CreateParams {
        address collateral; // ERC-20 collateral (e.g. USDC)
        address resolver; // the only address allowed to resolve/invalidate this market
        uint64 closeTime; // trading allowed while block.timestamp < closeTime
        uint32 outcomeCount; // 2..MAX_LMSR_OUTCOMES; 2 == binary Yes/No
        uint16 feeBps; // trading fee (<= MAX_FEE_BPS), taken on buys and sells
        uint256 b; // LMSR liquidity parameter (larger => deeper, less price impact)
        bytes32 category; // free-form category tag
        bytes32 metadataHash; // pointer/hash to off-chain details
    }

    struct Market {
        // ---- immutable config ----
        address collateral;
        address resolver;
        uint64 closeTime;
        uint32 outcomeCount;
        uint16 feeBps;
        uint256 b;
        bytes32 category;
        bytes32 metadataHash;
        address lp; // liquidity provider / subsidy funder (the market creator)
        // ---- mutable state ----
        MarketTypes.Status status;
        uint32 winningOutcomeId;
        uint256 pot; // collateral backing this market; equals C(q)
        uint256 sumPositiveNet; // Σ over users of max(netContributed, 0); used for fair invalidation
        uint256 lpPayout; // LP settlement, fixed at resolution/invalidation
        // ---- ledgers ----
        mapping(uint256 => uint256) q; // outcomeId => net shares outstanding (the LMSR state)
        mapping(address => mapping(uint256 => uint256)) shares; // owner => outcomeId => shares held
        mapping(address => int256) netContributed; // owner => cost basis in - refunds out
        mapping(address => bool) redeemed; // owner => already redeemed
        bool lpRedeemed;
    }

    struct MarketView {
        address collateral;
        address resolver;
        uint64 closeTime;
        uint32 outcomeCount;
        uint16 feeBps;
        uint256 b;
        bytes32 category;
        bytes32 metadataHash;
        address lp;
        MarketTypes.Status status;
        uint32 winningOutcomeId;
        uint256 pot;
        uint256 lpPayout;
        bool tradingOpen;
    }

    uint256 public marketCount;
    mapping(uint256 => Market) internal markets;

    /// @notice Protocol fees accrued per collateral token, pending withdrawal.
    mapping(address => uint256) public accruedFees;

    // -------------------------------------------------------------------------
    // Events (the `account` is the unlinkable ExecutionAccount; prices are public)
    // -------------------------------------------------------------------------

    event MarketCreated(
        uint256 indexed marketId,
        address indexed collateral,
        address resolver,
        uint64 closeTime,
        uint32 outcomeCount,
        uint16 feeBps,
        uint256 b,
        uint256 subsidy,
        bytes32 category,
        bytes32 metadataHash,
        address lp
    );
    event Bought(
        uint256 indexed marketId,
        address indexed account,
        uint256 indexed outcomeId,
        uint256 shares,
        uint256 cost,
        uint256 fee,
        uint256 newQ
    );
    event Sold(
        uint256 indexed marketId,
        address indexed account,
        uint256 indexed outcomeId,
        uint256 shares,
        uint256 refund,
        uint256 fee,
        uint256 newQ
    );
    event MarketResolved(
        uint256 indexed marketId, uint32 winningOutcomeId, uint256 winningShares, uint256 lpPayout
    );
    event MarketInvalidated(uint256 indexed marketId, uint256 lpPayout);
    event Redeemed(uint256 indexed marketId, address indexed account, uint256 amount);
    event LiquidityRedeemed(uint256 indexed marketId, address indexed lp, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.MARKET_CREATOR_ROLE, admin);
        _grantRole(Roles.PAUSER_ROLE, admin);
        _grantRole(Roles.FEE_MANAGER_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Market creation (seeds the bounded-loss subsidy C(0) = b*ln(N))
    // -------------------------------------------------------------------------

    function createMarket(CreateParams calldata p)
        external
        onlyRole(Roles.MARKET_CREATOR_ROLE)
        returns (uint256 marketId)
    {
        if (p.collateral == address(0) || p.resolver == address(0)) {
            revert ZeroAddress();
        }
        if (p.outcomeCount < Constants.MIN_OUTCOMES || p.outcomeCount > Constants.MAX_LMSR_OUTCOMES) {
            revert InvalidOutcomeCount(p.outcomeCount, Constants.MIN_OUTCOMES, Constants.MAX_LMSR_OUTCOMES);
        }
        if (p.feeBps > Constants.MAX_FEE_BPS) revert FeeTooHigh(p.feeBps, Constants.MAX_FEE_BPS);
        if (p.closeTime <= block.timestamp) revert CloseTimeInPast(p.closeTime, uint64(block.timestamp));
        if (p.b == 0) revert ZeroLiquidity();
        if (p.b > Constants.MAX_LIQUIDITY_PARAM) revert LiquidityTooHigh(p.b, Constants.MAX_LIQUIDITY_PARAM);

        uint256 subsidy = LMSRMath.cost(new uint256[](p.outcomeCount), p.b);

        marketId = marketCount++;
        Market storage m = markets[marketId];
        m.collateral = p.collateral;
        m.resolver = p.resolver;
        m.closeTime = p.closeTime;
        m.outcomeCount = p.outcomeCount;
        m.feeBps = p.feeBps;
        m.b = p.b;
        m.category = p.category;
        m.metadataHash = p.metadataHash;
        m.lp = msg.sender;

        uint256 received = _pull(p.collateral, msg.sender, subsidy);
        if (received < subsidy) revert AmountBelowMin(received, subsidy); // exact collateral required
        m.pot = subsidy;

        emit MarketCreated(
            marketId,
            p.collateral,
            p.resolver,
            p.closeTime,
            p.outcomeCount,
            p.feeBps,
            p.b,
            subsidy,
            p.category,
            p.metadataHash,
            msg.sender
        );
    }

    // -------------------------------------------------------------------------
    // Trading (each trade shifts the public prices)
    // -------------------------------------------------------------------------

    /// @notice Buy `sharesOut` shares of `outcomeId`. Raises `q` and the outcome's price.
    /// @param maxCost Maximum total collateral (cost + fee) the caller will pay (slippage guard).
    /// @return totalPaid Collateral pulled from the caller (cost + fee).
    function buy(uint256 marketId, uint256 outcomeId, uint256 sharesOut, uint256 maxCost)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 totalPaid)
    {
        Market storage m = _get(marketId);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        if (block.timestamp >= m.closeTime) revert MarketClosed(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        if (sharesOut == 0) revert AmountZero();
        if (sharesOut > Constants.MAX_SHARES_PER_TRADE) {
            revert AmountTooLarge(sharesOut, Constants.MAX_SHARES_PER_TRADE);
        }

        uint256 baseCost = LMSRMath.costToBuy(_loadQ(m), m.b, outcomeId, sharesOut);
        uint256 fee = _fee(baseCost, m.feeBps);
        totalPaid = baseCost + fee;
        if (totalPaid > maxCost) revert SlippageExceeded(totalPaid, maxCost);

        uint256 received = _pull(m.collateral, msg.sender, totalPaid);
        if (received < totalPaid) revert AmountBelowMin(received, totalPaid);

        uint256 newQ = m.q[outcomeId] + sharesOut;
        m.q[outcomeId] = newQ;
        m.shares[msg.sender][outcomeId] += sharesOut;
        m.pot += baseCost;
        if (fee > 0) accruedFees[m.collateral] += fee;
        _addContribution(m, msg.sender, int256(baseCost));

        emit Bought(marketId, msg.sender, outcomeId, sharesOut, baseCost, fee, newQ);
    }

    /// @notice Sell `sharesIn` shares of `outcomeId` back to the maker. Lowers `q` and the price.
    /// @param minRefund Minimum net collateral (after fee) the caller will accept (slippage guard).
    /// @return refundOut Net collateral paid to the caller.
    function sell(uint256 marketId, uint256 outcomeId, uint256 sharesIn, uint256 minRefund)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 refundOut)
    {
        Market storage m = _get(marketId);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        if (block.timestamp >= m.closeTime) revert MarketClosed(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        if (sharesIn == 0) revert AmountZero();

        uint256 have = m.shares[msg.sender][outcomeId];
        if (sharesIn > have) revert InsufficientShares(have, sharesIn);

        uint256 grossRefund = LMSRMath.refundToSell(_loadQ(m), m.b, outcomeId, sharesIn);
        uint256 fee = _fee(grossRefund, m.feeBps);
        refundOut = grossRefund - fee;
        if (refundOut < minRefund) revert SlippageExceeded(refundOut, minRefund);

        uint256 newQ = m.q[outcomeId] - sharesIn;
        m.q[outcomeId] = newQ;
        m.shares[msg.sender][outcomeId] = have - sharesIn;
        m.pot -= grossRefund;
        if (fee > 0) accruedFees[m.collateral] += fee;
        _addContribution(m, msg.sender, -int256(grossRefund));

        IERC20(m.collateral).safeTransfer(msg.sender, refundOut);
        emit Sold(marketId, msg.sender, outcomeId, sharesIn, refundOut, fee, newQ);
    }

    // -------------------------------------------------------------------------
    // Resolution (restricted to the market's bound resolver)
    // -------------------------------------------------------------------------

    /// @inheritdoc IResolvableMarket
    function resolve(uint256 marketId, uint256 winningOutcomeId) external {
        Market storage m = _get(marketId);
        if (msg.sender != m.resolver) revert NotResolver(msg.sender);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        if (block.timestamp < m.closeTime) revert MarketNotClosed(marketId);
        if (winningOutcomeId >= m.outcomeCount) revert InvalidOutcome(winningOutcomeId, m.outcomeCount);

        m.winningOutcomeId = uint32(winningOutcomeId);
        m.status = MarketTypes.Status.Resolved;
        uint256 winningShares = m.q[winningOutcomeId];
        m.lpPayout = m.pot - winningShares; // pot >= C(q) >= q_winner, so this is >= 0

        emit MarketResolved(marketId, uint32(winningOutcomeId), winningShares, m.lpPayout);
    }

    /// @inheritdoc IResolvableMarket
    /// @dev Void the market. Traders reclaim their net cost basis; the LP takes the residual
    ///      (`pot - Σ positive net contributions`), which is >= 0 by LMSR's bounded-loss property.
    function invalidate(uint256 marketId) external {
        Market storage m = _get(marketId);
        if (msg.sender != m.resolver) revert NotResolver(msg.sender);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);

        m.status = MarketTypes.Status.Invalid;
        m.lpPayout = m.pot - m.sumPositiveNet;
        emit MarketInvalidated(marketId, m.lpPayout);
    }

    // -------------------------------------------------------------------------
    // Redemption (paid to msg.sender -> sweepable back into the shielded pool)
    // -------------------------------------------------------------------------

    /// @notice Redeem after settlement. Resolved: winning shares pay 1:1. Invalid: net cost basis back.
    function redeem(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _get(marketId);
        if (m.redeemed[msg.sender]) revert AlreadyClaimed();

        if (m.status == MarketTypes.Status.Resolved) {
            amount = m.shares[msg.sender][m.winningOutcomeId];
            if (amount == 0) revert NothingToClaim();
            m.shares[msg.sender][m.winningOutcomeId] = 0;
        } else if (m.status == MarketTypes.Status.Invalid) {
            int256 nc = m.netContributed[msg.sender];
            amount = nc > 0 ? uint256(nc) : 0;
            if (amount == 0) revert NothingToClaim();
            m.netContributed[msg.sender] = 0;
        } else {
            revert MarketNotResolved(marketId);
        }

        m.redeemed[msg.sender] = true;
        m.pot -= amount;
        IERC20(m.collateral).safeTransfer(msg.sender, amount);
        emit Redeemed(marketId, msg.sender, amount);
    }

    /// @notice Liquidity provider withdraws their settlement after the market is resolved or voided.
    function redeemLiquidity(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _get(marketId);
        if (msg.sender != m.lp) revert NotAuthorized(msg.sender);
        if (m.lpRedeemed) revert AlreadyClaimed();
        if (m.status != MarketTypes.Status.Resolved && m.status != MarketTypes.Status.Invalid) {
            revert MarketNotResolved(marketId);
        }

        m.lpRedeemed = true;
        amount = m.lpPayout;
        if (amount > 0) {
            m.pot -= amount;
            IERC20(m.collateral).safeTransfer(msg.sender, amount);
        }
        emit LiquidityRedeemed(marketId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Protocol fees & pause
    // -------------------------------------------------------------------------

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

    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Views — public prices & market data
    // -------------------------------------------------------------------------

    function getMarket(uint256 marketId) external view returns (MarketView memory v) {
        Market storage m = _get(marketId);
        v = MarketView({
            collateral: m.collateral,
            resolver: m.resolver,
            closeTime: m.closeTime,
            outcomeCount: m.outcomeCount,
            feeBps: m.feeBps,
            b: m.b,
            category: m.category,
            metadataHash: m.metadataHash,
            lp: m.lp,
            status: m.status,
            winningOutcomeId: m.winningOutcomeId,
            pot: m.pot,
            lpPayout: m.lpPayout,
            tradingOpen: m.status == MarketTypes.Status.Trading && block.timestamp < m.closeTime
        });
    }

    /// @notice Current public marginal prices for every outcome, in WAD (sums to ~1e18).
    function prices(uint256 marketId) external view returns (uint256[] memory) {
        Market storage m = _get(marketId);
        return LMSRMath.prices(_loadQ(m), m.b);
    }

    /// @notice Current public price of a single outcome, in WAD.
    function priceWad(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        Market storage m = _get(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        return LMSRMath.prices(_loadQ(m), m.b)[outcomeId];
    }

    /// @notice Betting close time of a market (engine-agnostic getter used by resolvers).
    function closeTimeOf(uint256 marketId) external view returns (uint64) {
        return _get(marketId).closeTime;
    }

    /// @notice Number of outcomes of a market (engine-agnostic getter used by resolvers).
    function outcomeCountOf(uint256 marketId) external view returns (uint32) {
        return _get(marketId).outcomeCount;
    }

    /// @notice Net shares outstanding for an outcome (the LMSR state `q_i`).
    function outcomeShares(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        return _get(marketId).q[outcomeId];
    }

    /// @notice An account's share holding for an outcome.
    function sharesOf(uint256 marketId, address account, uint256 outcomeId) external view returns (uint256) {
        return _get(marketId).shares[account][outcomeId];
    }

    /// @notice Quote the total cost (cost + fee) to buy `sharesOut` of `outcomeId` right now.
    function quoteBuy(uint256 marketId, uint256 outcomeId, uint256 sharesOut)
        external
        view
        returns (uint256 baseCost, uint256 fee, uint256 totalCost)
    {
        Market storage m = _get(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        baseCost = LMSRMath.costToBuy(_loadQ(m), m.b, outcomeId, sharesOut);
        fee = _fee(baseCost, m.feeBps);
        totalCost = baseCost + fee;
    }

    /// @notice Quote the net refund (after fee) to sell `sharesIn` of `outcomeId` right now.
    function quoteSell(uint256 marketId, uint256 outcomeId, uint256 sharesIn)
        external
        view
        returns (uint256 grossRefund, uint256 fee, uint256 netRefund)
    {
        Market storage m = _get(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        grossRefund = LMSRMath.refundToSell(_loadQ(m), m.b, outcomeId, sharesIn);
        fee = _fee(grossRefund, m.feeBps);
        netRefund = grossRefund - fee;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _get(uint256 marketId) internal view returns (Market storage m) {
        if (marketId >= marketCount) revert MarketNotFound(marketId);
        m = markets[marketId];
    }

    function _loadQ(Market storage m) internal view returns (uint256[] memory q) {
        uint256 n = m.outcomeCount;
        q = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            q[i] = m.q[i];
        }
    }

    function _fee(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return (amount * feeBps) / Constants.BPS;
    }

    function _pull(address token, address from, uint256 amount) internal returns (uint256 received) {
        IERC20 t = IERC20(token);
        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(from, address(this), amount);
        received = t.balanceOf(address(this)) - balBefore;
    }

    /// @dev Update a user's net cost basis and keep the `sumPositiveNet` aggregate in sync (O(1)).
    ///      `sumPositiveNet = Σ_users max(netContributed, 0)`, snapshotted at invalidation to split
    ///      the pot exactly between traders (their money back) and the LP (the residual).
    function _addContribution(Market storage m, address user, int256 delta) internal {
        int256 oldC = m.netContributed[user];
        int256 newC = oldC + delta;
        m.netContributed[user] = newC;
        // Casts are guarded by `> 0`, so the values are always non-negative and fit uint256.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 oldPos = oldC > 0 ? uint256(oldC) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 newPos = newC > 0 ? uint256(newC) : 0;
        m.sumPositiveNet = m.sumPositiveNet + newPos - oldPos;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {SD59x18} from "@prb/math/src/SD59x18.sol";

import {Constants} from "../libraries/Constants.sol";
import {MarketTypes} from "../libraries/MarketTypes.sol";
import {LsLmsr} from "../libraries/LsLmsr.sol";
import {Roles} from "../access/Roles.sol";
import {IResolvableMarket} from "../interfaces/IResolvableMarket.sol";
import {IMarketEngine} from "../interfaces/IMarketEngine.sol";
import {ITradingBlocklist} from "../interfaces/ITradingBlocklist.sol";
import {
    ZeroAddress,
    InvalidOutcomeCount,
    CloseTimeInPast,
    InvalidStartTime,
    MarketNotOpenYet,
    MetadataMismatch,
    MarketNotFound,
    MarketNotTrading,
    MarketClosed,
    MarketNotClosed,
    MarketNotResolved,
    InvalidOutcome,
    AmountZero,
    NothingToClaim,
    AlreadyClaimed,
    NotResolver,
    NotAuthorized,
    SlippageExceeded,
    InsufficientShares,
    AmountTooLarge,
    AmountBelowMin
} from "../libraries/Errors.sol";

/// @title LsLmsrMarket
/// @notice Damped LS-LMSR prediction markets: long any outcome, short any outcome, exit any time.
///
/// @dev ## What this replaces and why
///
/// A parimutuel pool only lets a trader buy in and wait. This engine is a cost-function AMM, so a
/// position can be opened, added to, reduced and closed at a continuously quoted price — and the
/// pool provably cannot run out of money, which a pro-rata pool cannot promise once you allow exits.
///
/// ## The three primitives
///
///  - `buy(i)`            long outcome `i`.
///  - `buyComplement(i)`  short outcome `i`, by buying one share of every other outcome. Because the
///                        outcomes are exhaustive, exactly one of them wins whenever `i` loses, so
///                        the basket pays 1 per share precisely when `i` loses. There is deliberately
///                        no separate short primitive: a synthetic short would need its own
///                        collateral rules, whereas a basket of longs inherits solvency unchanged.
///  - `sell(i)`           reduce or exit, at the curve's price.
///
/// ## Units
///
/// `q` and `collateralHeld` are stored in the collateral's own base units, so a share redeems for
/// exactly one base unit and settlement is integer-exact with no dust. {LsLmsr} works in WAD, so
/// quantities are scaled up by {Market.scale} = `10^(18 − decimals)` at the boundary and the
/// resulting WAD cost is converted back — up for anything charged, down for anything paid out.
///
/// Storing WAD internally instead would have been the obvious route and is wrong: 1e18 of `q`
/// against 6-decimal USDC redeems 1e12 times the intended amount, and every payout would have to
/// carry a rounding remainder.
///
/// ## Solvency
///
/// `C(q) ≥ max(qᵢ)` identically (see {LsLmsr}), and collateral tracks `C` from above because every
/// charge rounds up and every payout rounds down. That is the design argument — but it is NOT
/// trusted at runtime. {_assertSolvent} re-checks `collateralHeld ≥ max(qᵢ)` after every state
/// change and reverts, because the margin `C(q) − max(qᵢ)` is the entropy term and legitimately
/// shrinks toward zero as a book approaches certainty. Measured during Phase 1 invariant runs: a
/// skewed book held 27,477.1109 against a 27,477.1074 payout — a buffer of 0.0035. At that point the
/// curve is no longer self-protecting and only the explicit assertion is.
///
/// ## Privacy
///
/// Positions are keyed on `_msgSender()` and payouts go to `_msgSender()`. The trader is a
/// per-market address derived in the user's browser, funded by a shielded-pool withdrawal whose
/// source account is private, so nothing on chain ties it back to a wallet. Prices and volumes are
/// public; who traded is not.
///
/// Two things make that hold, and both are load-bearing:
///
///  - **No `tx.origin`, no signature recovery over trader intent, no assumption that the trader
///    holds native gas.** Each of those would leak the trader or force a public gas transfer into
///    their account, which publishes the same link permanently.
///  - **`_msgSender()`, not `msg.sender`, on every trader path.** A market account has no native
///    balance and cannot send its own transactions; it signs, and {NumeraForwarder} relays. A
///    `msg.sender` left behind on a trader path would credit the forwarder instead of the trader —
///    silently pooling every user's position into one address.
///
/// Conversely, {notRelayed} marks every path that must NOT be reachable through the forwarder:
/// creation, resolution, seed redemption and admin. The forwarder's own selector allowlist already
/// excludes them, so this is the second of two independent locks — worth having, because the cost of
/// the first one failing is somebody resolving a market as its own resolver.
///
/// ## Deviation from the brief
///
/// The brief describes one deployed contract per market. This hosts many markets behind a `marketId`
/// instead, matching {LMSRMarket} — the engine it replaces — so the indexer, API and frontend keep
/// working against the same shape. Collateral is still strictly per-market: every balance change is
/// bounded by that market's own `collateralHeld`, so one market can never pay another's winners.
/// @dev {ERC2771Context} is listed last so its `_msgSender()` override is the most derived one, and
///      therefore the one {AccessControl} and {Pausable} resolve to as well. Reordering this line
///      would silently return the forwarder's address to every inherited role check.
contract LsLmsrMarket is
    IResolvableMarket,
    IMarketEngine,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    ERC2771Context
{
    using SafeERC20 for IERC20;

    uint256 private constant WAD = Constants.WAD;

    /// @notice Outcome bounds. Above four, decompose into separate binary markets.
    uint256 public constant MIN_OUTCOMES = 2;
    uint256 public constant MAX_OUTCOMES = LsLmsr.MAX_OUTCOMES;

    /// @notice Bounds on `α`, the liquidity coefficient.
    uint256 public constant MIN_ALPHA = 1e15;
    uint256 public constant MAX_ALPHA = 1e17;

    /// @notice Ceiling on the damping scale `s*`, in WAD.
    uint256 public constant MAX_S_STAR = 1e24;

    /// @notice Floor on total shares `s = Σqᵢ`, in WAD.
    ///
    /// @dev `b'(s) = α(1 + ½√(s*/s)) → ∞` as `s → 0`, so quoted spreads diverge and `pᵢ` eventually
    ///      exceeds 1 — at `s ≈ 0.645` for the binary defaults. Ten shares keeps a wide margin from
    ///      that edge while still being a genuinely small seed: at `s = 10` the vig is about 28%,
    ///      falling to 11% at 100 and 5.2% at 2,000. The floor is structural rather than merely
    ///      checked, because the creator's seed is never credited to the share ledger and so can
    ///      never be sold back out.
    uint256 public constant MIN_TOTAL_SHARES_WAD = 10e18;

    /// @notice Collateral must have at most 18 decimals, so the WAD scale factor is an integer.
    uint256 public constant MAX_COLLATERAL_DECIMALS = 18;

    /// @notice Spread overlay coefficients, applied on top of the cost function and never inside it.
    /// @dev Keeping `φ` outside `C` is what preserves path independence: `C` stays a pure function of
    ///      `q`, so the cost of any route between two states is identical and no round trip can be
    ///      engineered into a profit.
    uint256 public constant PHI_BASE = 0.005e18;
    uint256 public constant PHI_TIME = 0.015e18;
    uint256 public constant PHI_SKEW = 0.01e18;

    /// @dev Collateral that does not deliver exactly what was sent breaks the AMM's accounting.
    error UnsupportedCollateral();
    error AlphaOutOfRange(uint256 provided, uint256 min, uint256 max);
    error DampingOutOfRange(uint256 provided, uint256 max);
    error SeedTooSmall(uint256 totalWad, uint256 minWad);
    error Insolvent(uint256 collateral, uint256 owed);
    error PriceSumBelowOne(uint256 sum);
    error SeedLocked();
    error FeeTooHigh(uint16 provided, uint16 max);
    /// @dev A path that must never be reachable through {NumeraForwarder} was called by it.
    error RelayNotAllowed();
    error NothingToSweep();
    /// @dev The account staked a bond on an outcome arbitration found to be false.
    error AccountBanned(address account);

    struct CreateParams {
        address collateral;
        address resolver;
        /**
         * When trading opens. Trading is allowed while `startTime <= block.timestamp < closeTime`.
         *
         * The engine had a close and no open, so a market was tradeable from the instant its
         * creating transaction mined and a scheduled book could not be published in advance. Pass
         * `0` for "open immediately", which is stored as the creation timestamp rather than left
         * as a sentinel, so every market has a real opening instant to display and to prove.
         */
        uint64 startTime;
        uint64 closeTime;
        uint32 outcomeCount;
        /// Liquidity coefficient, WAD. Immutable: mutating it would make `C` history-dependent and
        /// open a risk-free round trip across the change.
        uint256 alpha;
        /// Damping scale, WAD. `0` gives pure LS-LMSR. Also immutable, for the same reason.
        uint256 sStar;
        /// Shares of EVERY outcome the creator seeds, in collateral base units. Locked until
        /// resolution.
        uint256 seedPerOutcome;
        bytes32 category;
        bytes32 metadataHash;
        /**
         * The canonical metadata JSON this market commits to.
         *
         * Passed in full and checked against {metadataHash} here, then emitted rather than stored:
         * calldata and logs are on chain and immutable, and storing a few hundred bytes of prose in
         * state would cost more gas than the trade it is describing. Anyone can read the title, the
         * outcome labels and the settlement rules straight out of the creation log and hash them
         * back to the commitment the engine holds forever.
         *
         * This is what makes "the rules cannot be changed" a fact about the chain rather than a
         * promise about our database.
         */
        string metadata;
    }

    struct Market {
        address collateral;
        address resolver;
        address creator;
        uint64 createdAt;
        uint64 startTime;
        uint64 closeTime;
        uint32 outcomeCount;
        /// `10^(18 − collateral decimals)`. Base units × scale = WAD.
        uint256 scale;
        uint256 alpha;
        uint256 sStar;
        uint256 seed;
        bytes32 category;
        bytes32 metadataHash;
        MarketTypes.Status status;
        uint32 winningOutcomeId;
        /// This market's own collateral, base units. Never spendable by any other market.
        uint256 collateralHeld;
        /// Σ over traders of max(netContributed, 0), for fair refunds if the market is voided.
        uint256 sumPositiveNet;
        bool seedRedeemed;
        mapping(uint256 => uint256) q;
        mapping(address => mapping(uint256 => uint256)) shares;
        mapping(address => int256) netContributed;
        mapping(address => bool) redeemed;
    }

    struct MarketView {
        address collateral;
        address resolver;
        address creator;
        uint64 createdAt;
        uint64 startTime;
        uint64 closeTime;
        uint32 outcomeCount;
        uint256 alpha;
        uint256 sStar;
        uint256 seed;
        bytes32 category;
        bytes32 metadataHash;
        MarketTypes.Status status;
        uint32 winningOutcomeId;
        uint256 collateralHeld;
        uint256 totalShares;
        bool tradingOpen;
    }

    uint256 public marketCount;
    mapping(uint256 => Market) internal markets;

    /// @notice Where resolution surplus and swept trading fees go. Mutable by design; nothing else
    ///         about a market is.
    address public feeRecipient;

    /// @notice Hard ceiling on the trading fee, in basis points. Not settable — this is the promise
    ///         that the fee cannot be raised arbitrarily after traders have taken positions.
    uint16 public constant MAX_TRADE_FEE_BPS = 500;

    /// @notice Fee charged on the cost of a buy and on the proceeds of a sell, in basis points.
    ///
    /// @dev Zero at construction, deliberately. Turning the fee on is a deployment step, so the
    ///      engine's behaviour is unchanged for anything that constructs it without one, and every
    ///      existing price and cost assertion keeps its meaning.
    ///
    ///      Settlement is free: a winner redeeming has already paid on the way in, and charging
    ///      again at `redeem` would be a second bite of the same trade.
    uint16 public tradeFeeBps;

    /// @notice Smallest trade the engine will accept, per collateral token, in base units.
    ///
    /// @dev This is the anti-abuse bound for sponsored gas, not a UX preference, and it is the
    ///      reason {NumeraForwarder} can be safely unauthenticated.
    ///
    ///      Trades are relayed at Numera's expense. Nothing can distinguish an attacker's tiny trade
    ///      from an honest one — they are both real trades — so no signature check can stop somebody
    ///      spending our gas. What stops it is arithmetic: set this so the fee on the smallest legal
    ///      trade is worth several times the gas of relaying it, and the attack costs the attacker
    ///      more than it costs us, at every size, with no identity check anywhere.
    ///
    ///      Per token rather than global because the floor is denominated in the collateral, and two
    ///      collaterals with different decimals have no common base unit.
    ///
    ///      A full exit is always allowed regardless (see {sell}), so this can never trap a position
    ///      below the floor.
    mapping(address token => uint256 minimum) public minTradeCost;

    /// @notice Fees taken and not yet swept, per collateral token.
    ///
    /// @dev Accrued rather than transferred per trade: one storage write costs a fraction of an
    ///      ERC-20 transfer, and on Monad — which bills the gas limit rather than the gas used —
    ///      every avoided operation lowers the limit the relayer has to declare.
    ///
    ///      Held separately from {Market.collateralHeld} and never counted as market collateral, so
    ///      the solvency invariant is untouched by fees: {_assertSolvent} reads `collateralHeld`,
    ///      which only ever grows by the trade's own cost. The contract's token balance is
    ///      `Σ collateralHeld + feesAccrued`, and no accounting path reads `balanceOf`.
    mapping(address token => uint256 amount) public feesAccrued;

    /// @notice Lifetime fees this market has earned, base units of its own collateral.
    ///
    /// @dev {feesAccrued} is per token and global, which answers "what has the protocol earned" but
    ///      not "what did *this* market earn". The resolver needs the second question: whoever is
    ///      proved right about an outcome is paid a share of the revenue that market generated, so
    ///      the reward has to be sized against a per-market figure or it is not that share at all.
    ///
    ///      Purely additive bookkeeping. It is never subtracted from, never spent, and no accounting
    ///      path reads it — sweeping still works off {feesAccrued}. It is a record of what happened.
    mapping(uint256 marketId => uint256 amount) public feesOf;

    /// @notice The shared ban list, or zero when this engine enforces none.
    ///
    /// @dev Immutable for the same reason as {ERC2771Context}'s forwarder: a settable list is an
    ///      admin switch for freezing any trader, which is a larger power than the one this needs.
    ///      Replacing the list means replacing the engine, and that is the correct amount of
    ///      friction for a change of that size.
    ITradingBlocklist public immutable blocklist;

    event MarketCreated(
        uint256 indexed marketId,
        address indexed collateral,
        address indexed creator,
        address resolver,
        uint32 outcomeCount,
        uint64 startTime,
        uint64 closeTime,
        uint256 alpha,
        uint256 sStar,
        uint256 seedPerOutcome,
        uint256 seedCost,
        bytes32 category,
        bytes32 metadataHash
    );
    /**
     * @notice The canonical metadata a market committed to, published in full.
     * @dev Emitted once, in the creation transaction, and never again — there is no function that
     *      can supersede it. `keccak256(metadata)` equals the `metadataHash` stored on the market,
     *      checked before this fires, so the log and the commitment cannot disagree.
     */
    event MarketMetadataPublished(uint256 indexed marketId, bytes32 indexed metadataHash, string metadata);
    event Bought(
        uint256 indexed marketId,
        address indexed account,
        uint256 indexed outcomeId,
        uint256 shares,
        uint256 cost,
        uint256 spreadWad
    );
    event Shorted(
        uint256 indexed marketId,
        address indexed account,
        uint256 indexed outcomeId,
        uint256 shares,
        uint256 cost,
        uint256 spreadWad
    );
    event Sold(
        uint256 indexed marketId,
        address indexed account,
        uint256 indexed outcomeId,
        uint256 shares,
        uint256 proceeds,
        uint256 spreadWad
    );
    event MarketResolved(uint256 indexed marketId, uint32 winningOutcomeId, uint256 owed, uint256 surplus);
    event MarketInvalidated(uint256 indexed marketId, uint256 surplus);
    event Redeemed(uint256 indexed marketId, address indexed account, uint256 amount);
    event SeedRedeemed(uint256 indexed marketId, address indexed creator, uint256 amount);
    event FeeRecipientUpdated(address indexed previous, address indexed next);
    event TradeFeeUpdated(uint16 previous, uint16 next);
    event MinTradeCostUpdated(address indexed token, uint256 previous, uint256 next);
    event FeeCharged(uint256 indexed marketId, address indexed account, uint256 fee);
    event FeesSwept(address indexed token, address indexed recipient, uint256 amount);

    /// @param trustedForwarder_ The {NumeraForwarder} allowed to speak for market accounts. Immutable
    ///        once set, and pass `address(0)` to disable relaying entirely — a settable trusted
    ///        forwarder would be an admin switch for impersonating any trader, which is not a power
    ///        anybody should hold over this contract.
    /// @param blocklist_ The shared {TradingBlocklist}, or `address(0)` to enforce no bans at all.
    constructor(address admin, address feeRecipient_, address trustedForwarder_, address blocklist_)
        ERC2771Context(trustedForwarder_)
    {
        if (admin == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        blocklist = ITradingBlocklist(blocklist_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.MARKET_CREATOR_ROLE, admin);
        _grantRole(Roles.PAUSER_ROLE, admin);
        _grantRole(Roles.FEE_MANAGER_ROLE, admin);
        feeRecipient = feeRecipient_;
    }

    /// @dev Marks a path that must never be reachable through the forwarder.
    ///
    ///      Necessary because {AccessControl} resolves its role checks through `_msgSender()`, which
    ///      {ERC2771Context} rewrites. Without this, the forwarder's selector allowlist would be the
    ///      *only* thing standing between a relayed call and an admin function, and a single mistake
    ///      in that list would be enough to resolve a market or move the fee recipient.
    modifier notRelayed() {
        if (isTrustedForwarder(msg.sender)) revert RelayNotAllowed();
        _;
    }

    // -------------------------------------------------------------------------
    // Creation
    // -------------------------------------------------------------------------

    /// @notice Create a market and seed it, in one transaction.
    ///
    /// @dev The creator buys `seedPerOutcome` of EVERY outcome. Their cost is `S + b·ln(n)` and they
    ///      redeem `S` at resolution whichever outcome wins, so their loss is exactly `b·ln(n)` —
    ///      deterministic, bounded and independent of the result. That is the entire subsidy: there
    ///      are no LPs, no protocol funding and no ongoing exposure.
    ///
    ///      Note the brief's §9 states this cost as `S·(1 + α·n·ln n)`, which is the `s* = 0` case.
    ///      With damping it is `S + α(nS + √(nS·s*))·ln n` — at `S = 1000` per outcome on the binary
    ///      defaults that is a loss of 69.31, not the 34.66 the undamped formula implies.
    function createMarket(CreateParams calldata p)
        external
        notRelayed
        onlyRole(Roles.MARKET_CREATOR_ROLE)
        nonReentrant
        returns (uint256 marketId)
    {
        uint256 scale = _validateAndScale(p);
        marketId = marketCount++;
        _writeConfig(marketId, p, scale);
        uint256 seedCost = _seedBook(marketId, p, scale);

        _emitCreated(marketId, p, seedCost);
    }

    /// @dev The emit gets its own frame: twelve arguments plus the creation locals overflow the
    ///      stack under the non-IR pipeline, and splitting is cheaper than switching the whole repo
    ///      to via-ir for one event.
    function _emitCreated(uint256 marketId, CreateParams calldata p, uint256 seedCost) private {
        emit MarketCreated(
            marketId,
            p.collateral,
            msg.sender,
            p.resolver,
            p.outcomeCount,
            markets[marketId].startTime,
            p.closeTime,
            p.alpha,
            p.sStar,
            p.seedPerOutcome,
            seedCost,
            p.category,
            p.metadataHash
        );
        emit MarketMetadataPublished(marketId, p.metadataHash, p.metadata);
    }

    // -------------------------------------------------------------------------
    // Trading
    // -------------------------------------------------------------------------

    /// @notice Long `outcomeId`: buy `sharesOut` shares for at most `maxCost`.
    function buy(uint256 marketId, uint256 outcomeId, uint256 sharesOut, uint256 maxCost)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 charged)
    {
        Market storage m = _tradable(marketId, outcomeId, sharesOut);
        address trader = _msgSender();
        _assertAllowed(trader);
        uint256 scale = m.scale;
        uint256[] memory qWad = _loadQ(m);

        uint256 cost;
        uint256 spread;
        (cost, spread) = _quoteBuy(m, qWad, outcomeId, sharesOut * scale, scale, false);
        uint256 fee = _feeOn(cost);
        charged = cost + fee;
        if (charged > maxCost) revert SlippageExceeded(charged, maxCost);
        _assertAboveMinimum(m.collateral, charged);

        _pullExact(m.collateral, trader, charged);
        m.q[outcomeId] += sharesOut;
        qWad[outcomeId] += sharesOut * scale;
        m.shares[trader][outcomeId] += sharesOut;
        m.collateralHeld += cost;
        _addContribution(m, trader, int256(cost));
        _accrueFee(marketId, m.collateral, trader, fee);

        _assertSolvent(m, qWad, scale);
        emit Bought(marketId, trader, outcomeId, sharesOut, charged, spread);
    }

    /// @notice Short `outcomeId`: buy `sharesOut` of every OTHER outcome, for at most `maxCost`.
    ///
    /// @dev Pays 1 per share exactly when `outcomeId` loses. For a binary market this is identical
    ///      to buying the other side, and the test suite asserts that equivalence — if the two ever
    ///      diverged, the basket would not be a clean short.
    function buyComplement(uint256 marketId, uint256 outcomeId, uint256 sharesOut, uint256 maxCost)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 charged)
    {
        Market storage m = _tradable(marketId, outcomeId, sharesOut);
        address trader = _msgSender();
        _assertAllowed(trader);
        uint256 scale = m.scale;
        uint256[] memory qWad = _loadQ(m);

        uint256 cost;
        uint256 spread;
        (cost, spread) = _quoteBuy(m, qWad, outcomeId, sharesOut * scale, scale, true);
        uint256 fee = _feeOn(cost);
        charged = cost + fee;
        if (charged > maxCost) revert SlippageExceeded(charged, maxCost);
        _assertAboveMinimum(m.collateral, charged);

        _pullExact(m.collateral, trader, charged);
        uint256 n = m.outcomeCount;
        for (uint256 j; j < n; ++j) {
            if (j == outcomeId) continue;
            m.q[j] += sharesOut;
            qWad[j] += sharesOut * scale;
            m.shares[trader][j] += sharesOut;
        }
        m.collateralHeld += cost;
        _addContribution(m, trader, int256(cost));
        _accrueFee(marketId, m.collateral, trader, fee);

        _assertSolvent(m, qWad, scale);
        emit Shorted(marketId, trader, outcomeId, sharesOut, charged, spread);
    }

    /// @notice Exit or reduce: sell `sharesIn` of `outcomeId` for at least `minRefund`.
    function sell(uint256 marketId, uint256 outcomeId, uint256 sharesIn, uint256 minRefund)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 proceeds)
    {
        Market storage m = _tradable(marketId, outcomeId, sharesIn);
        address trader = _msgSender();
        _assertAllowed(trader);
        uint256 held = m.shares[trader][outcomeId];
        // No shorting via negative inventory: a trader may only sell what they actually hold, which
        // is what keeps every `qᵢ ≥ seed` and therefore `s ≥ n·seed` structurally.
        if (held < sharesIn) revert InsufficientShares(held, sharesIn);

        uint256 scale = m.scale;
        uint256[] memory qWad = _loadQ(m);
        uint256 spread;
        // `gross` is what leaves the market; `proceeds` is what the trader receives.
        uint256 gross;
        (gross, spread) = _quoteSell(m, qWad, outcomeId, sharesIn * scale, scale);
        uint256 fee = _feeOn(gross);
        proceeds = gross - fee;
        if (proceeds < minRefund) revert SlippageExceeded(proceeds, minRefund);
        // A complete exit is exempt from the floor. Without this, a position worth less than the
        // minimum could never be closed at all — only abandoned until settlement — which would turn
        // an anti-abuse bound into a trap for the smallest traders.
        if (sharesIn != held) _assertAboveMinimum(m.collateral, proceeds);

        m.shares[trader][outcomeId] = held - sharesIn;
        m.q[outcomeId] -= sharesIn;
        qWad[outcomeId] -= sharesIn * scale;
        m.collateralHeld -= gross;
        _addContribution(m, trader, -int256(gross));
        _accrueFee(marketId, m.collateral, trader, fee);

        _assertSolvent(m, qWad, scale);
        IERC20(m.collateral).safeTransfer(trader, proceeds);
        emit Sold(marketId, trader, outcomeId, sharesIn, proceeds, spread);
    }

    /// @notice Close a short: sell `sharesIn` of every outcome EXCEPT `outcomeId`, in one call.
    ///
    /// @dev The exact counterpart of {buyComplement}, and it exists because closing a basket has to
    ///      be atomic. Selling the legs one at a time leaves a trader who fails on leg two holding
    ///      an unbalanced remainder that is no longer a short — and under sponsored execution each
    ///      leg would be a separate relayed transaction, so a partial close is not a remote
    ///      possibility but the ordinary consequence of one revert.
    ///
    ///      Legs are priced sequentially against a book that updates as each one sells, which is
    ///      exactly what selling them individually would do. `minRefund` is therefore a single
    ///      figure over the whole basket rather than one floor per leg: splitting an aggregate
    ///      blind would set an unreachable floor on the cheap legs of a skewed book while leaving
    ///      slack on the expensive ones, and rejecting a sale whose total was perfectly acceptable.
    ///
    ///      The fee is taken per leg rather than on the total, so `Σ Sold.proceeds` is exactly what
    ///      the trader receives and the indexer needs no special case for this path.
    function sellComplement(uint256 marketId, uint256 outcomeId, uint256 sharesIn, uint256 minRefund)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 proceeds)
    {
        Market storage m = _tradable(marketId, outcomeId, sharesIn);
        address trader = _msgSender();
        _assertAllowed(trader);
        uint256[] memory qWad = _loadQ(m);
        (uint256 gross, uint256 fee, bool complete) =
            _sellEveryOtherLeg(m, marketId, outcomeId, sharesIn, qWad);

        proceeds = gross - fee;
        if (proceeds < minRefund) revert SlippageExceeded(proceeds, minRefund);
        // As in {sell}: a complete exit is never blocked by the floor, or a basket worth less than
        // the minimum could only be abandoned until settlement.
        if (!complete) _assertAboveMinimum(m.collateral, proceeds);

        m.collateralHeld -= gross;
        _addContribution(m, trader, -int256(gross));
        _accrueFee(marketId, m.collateral, trader, fee);

        _assertSolvent(m, qWad, m.scale);
        IERC20(m.collateral).safeTransfer(trader, proceeds);
    }

    /// @dev The leg loop gets its own frame: the locals it needs plus the caller's overflow the
    ///      stack under the non-IR pipeline, the same reason {_emitCreated} is split out.
    ///
    ///      `complete` reports whether this closes the position entirely, which the caller needs in
    ///      order to waive the minimum. It is only true when *every* leg is fully sold — a basket
    ///      with one leg left over is still an open position.
    function _sellEveryOtherLeg(
        Market storage m,
        uint256 marketId,
        uint256 outcomeId,
        uint256 sharesIn,
        uint256[] memory qWad
    ) private returns (uint256 gross, uint256 fee, bool complete) {
        complete = true;
        for (uint256 j; j < m.outcomeCount; ++j) {
            if (j == outcomeId) continue;
            if (m.shares[_msgSender()][j] != sharesIn) complete = false;
            (uint256 legGross, uint256 legFee) = _sellOneLeg(m, marketId, j, sharesIn, qWad);
            gross += legGross;
            fee += legFee;
        }
    }

    /// @dev One leg of a basket sale, split out for stack room and shared with nothing else.
    ///      Mutates `qWad` so the next leg prices against the book this one leaves behind, which is
    ///      what makes the aggregate quote match the aggregate execution.
    function _sellOneLeg(
        Market storage m,
        uint256 marketId,
        uint256 outcomeId,
        uint256 sharesIn,
        uint256[] memory qWad
    ) private returns (uint256 legGross, uint256 legFee) {
        address trader = _msgSender();
        uint256 scale = m.scale;
        uint256 held = m.shares[trader][outcomeId];
        if (held < sharesIn) revert InsufficientShares(held, sharesIn);

        uint256 spread;
        (legGross, spread) = _quoteSell(m, qWad, outcomeId, sharesIn * scale, scale);
        legFee = _feeOn(legGross);

        m.shares[trader][outcomeId] = held - sharesIn;
        m.q[outcomeId] -= sharesIn;
        qWad[outcomeId] -= sharesIn * scale;
        emit Sold(marketId, trader, outcomeId, sharesIn, legGross - legFee, spread);
    }

    // -------------------------------------------------------------------------
    // Resolution
    // -------------------------------------------------------------------------

    /// @inheritdoc IResolvableMarket
    /// @dev Sweeps the surplus immediately and leaves the market holding exactly what it owes, so
    ///      from here `collateralHeld` is the outstanding winning shares and nothing else. That
    ///      makes under-payment structurally impossible rather than a matter of ordering.
    function resolve(uint256 marketId, uint256 winningOutcomeId) external notRelayed nonReentrant {
        Market storage m = _get(marketId);
        if (msg.sender != m.resolver) revert NotResolver(msg.sender);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        if (block.timestamp < m.closeTime) revert MarketNotClosed(marketId);
        if (winningOutcomeId >= m.outcomeCount) revert InvalidOutcome(winningOutcomeId, m.outcomeCount);

        uint256 owed = m.q[winningOutcomeId];
        uint256 held = m.collateralHeld;
        if (held < owed) revert Insolvent(held, owed);

        m.winningOutcomeId = uint32(winningOutcomeId);
        m.status = MarketTypes.Status.Resolved;

        uint256 surplus = held - owed;
        m.collateralHeld = owed;
        if (surplus > 0) IERC20(m.collateral).safeTransfer(feeRecipient, surplus);

        emit MarketResolved(marketId, uint32(winningOutcomeId), owed, surplus);
    }

    /// @inheritdoc IResolvableMarket
    /// @dev Void: traders reclaim their net cost basis. The residual is swept, and it is non-negative
    ///      because the curve's revenue always covers the sum of positive net contributions.
    function invalidate(uint256 marketId) external notRelayed nonReentrant {
        Market storage m = _get(marketId);
        if (msg.sender != m.resolver) revert NotResolver(msg.sender);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);

        uint256 owed = m.sumPositiveNet;
        uint256 held = m.collateralHeld;
        if (held < owed) revert Insolvent(held, owed);

        m.status = MarketTypes.Status.Invalid;
        uint256 surplus = held - owed;
        m.collateralHeld = owed;
        if (surplus > 0) IERC20(m.collateral).safeTransfer(feeRecipient, surplus);

        emit MarketInvalidated(marketId, surplus);
    }

    /// @notice Collect after settlement. Resolved: winning shares pay 1:1. Invalid: cost basis back.
    function redeem(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _get(marketId);
        address trader = _msgSender();
        if (m.redeemed[trader]) revert AlreadyClaimed();

        if (m.status == MarketTypes.Status.Resolved) {
            amount = m.shares[trader][m.winningOutcomeId];
            if (amount == 0) revert NothingToClaim();
            m.shares[trader][m.winningOutcomeId] = 0;
        } else if (m.status == MarketTypes.Status.Invalid) {
            int256 nc = m.netContributed[trader];
            amount = nc > 0 ? uint256(nc) : 0;
            if (amount == 0) revert NothingToClaim();
            m.netContributed[trader] = 0;
        } else {
            revert MarketNotResolved(marketId);
        }

        m.redeemed[trader] = true;
        m.collateralHeld -= amount;
        IERC20(m.collateral).safeTransfer(trader, amount);
        emit Redeemed(marketId, trader, amount);
    }

    /// @notice The creator reclaims their locked seed, once the market has settled.
    /// @dev The seed is never credited to the share ledger, which is what makes "locked until
    ///      resolution" structural: there is nothing for {sell} to find, so no code path can release
    ///      it early. Resolved pays `seed` (they hold that much of every outcome, including the
    ///      winner); voided pays nothing extra, since the seed cost is their bounded subsidy.
    function redeemSeed(uint256 marketId) external notRelayed nonReentrant returns (uint256 amount) {
        Market storage m = _get(marketId);
        if (msg.sender != m.creator) revert NotAuthorized(msg.sender);
        if (m.seedRedeemed) revert AlreadyClaimed();
        if (m.status == MarketTypes.Status.Trading) revert SeedLocked();

        m.seedRedeemed = true;
        if (m.status == MarketTypes.Status.Resolved) {
            amount = m.seed;
            m.collateralHeld -= amount;
            IERC20(m.collateral).safeTransfer(msg.sender, amount);
        }
        emit SeedRedeemed(marketId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setFeeRecipient(address next) external notRelayed onlyRole(Roles.FEE_MANAGER_ROLE) {
        if (next == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Set the trading fee, in basis points, bounded by {MAX_TRADE_FEE_BPS}.
    ///
    /// @dev Applies to trades from the next block onward and never retroactively: the fee is read at
    ///      trade time and every quote the frontend shows is derived from the same reading, so a
    ///      trader's slippage bound (`maxCost`/`minRefund`) protects them against a change landing
    ///      between quote and execution.
    function setTradeFee(uint16 nextBps) external notRelayed onlyRole(Roles.FEE_MANAGER_ROLE) {
        if (nextBps > MAX_TRADE_FEE_BPS) revert FeeTooHigh(nextBps, MAX_TRADE_FEE_BPS);
        emit TradeFeeUpdated(tradeFeeBps, nextBps);
        tradeFeeBps = nextBps;
    }

    /// @notice Set the smallest accepted trade for one collateral token, in its base units.
    /// @dev See {minTradeCost} for why this is a security parameter rather than a UX one.
    function setMinTradeCost(address token, uint256 next)
        external
        notRelayed
        onlyRole(Roles.FEE_MANAGER_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        emit MinTradeCostUpdated(token, minTradeCost[token], next);
        minTradeCost[token] = next;
    }

    /// @notice Send accrued trading fees for `token` to {feeRecipient}.
    ///
    /// @dev Role-gated rather than permissionless. It could safely be open — the destination is
    ///      fixed — but {feeRecipient} may be a contract, and letting any caller choose the moment an
    ///      arbitrary address is called into is surface worth not having. `nonReentrant` for the same
    ///      reason.
    ///
    ///      Touches only {feesAccrued}, never `collateralHeld`, so no market's solvency can be
    ///      affected by a sweep however it is timed.
    function sweepFees(address token)
        external
        notRelayed
        onlyRole(Roles.FEE_MANAGER_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        amount = feesAccrued[token];
        if (amount == 0) revert NothingToSweep();
        feesAccrued[token] = 0;
        address recipient = feeRecipient;
        IERC20(token).safeTransfer(recipient, amount);
        emit FeesSwept(token, recipient, amount);
    }

    function pause() external notRelayed onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external notRelayed onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getMarket(uint256 marketId) external view returns (MarketView memory v) {
        Market storage m = _get(marketId);
        uint256 total;
        for (uint256 i; i < m.outcomeCount; ++i) {
            total += m.q[i];
        }
        v = MarketView({
            collateral: m.collateral,
            resolver: m.resolver,
            creator: m.creator,
            createdAt: m.createdAt,
            startTime: m.startTime,
            closeTime: m.closeTime,
            outcomeCount: m.outcomeCount,
            alpha: m.alpha,
            sStar: m.sStar,
            seed: m.seed,
            category: m.category,
            metadataHash: m.metadataHash,
            status: m.status,
            winningOutcomeId: m.winningOutcomeId,
            collateralHeld: m.collateralHeld,
            totalShares: total,
            tradingOpen: m.status == MarketTypes.Status.Trading && block.timestamp >= m.startTime
                && block.timestamp < m.closeTime
        });
    }

    function prices(uint256 marketId) external view returns (uint256[] memory) {
        Market storage m = _get(marketId);
        return LsLmsr.prices(_loadQ(m), m.alpha, m.sStar);
    }

    /// @notice The spread a trade on `outcomeId` would pay right now, in WAD.
    function spreadWad(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        Market storage m = _get(marketId);
        return _spreadWad(m, outcomeId, _loadQ(m));
    }

    function quoteBuy(uint256 marketId, uint256 outcomeId, uint256 sharesOut)
        external
        view
        returns (uint256)
    {
        Market storage m = _get(marketId);
        (uint256 cost,) = _quoteBuy(m, _loadQ(m), outcomeId, sharesOut * m.scale, m.scale, false);
        return cost + _feeOn(cost);
    }

    function quoteBuyComplement(uint256 marketId, uint256 outcomeId, uint256 sharesOut)
        external
        view
        returns (uint256)
    {
        Market storage m = _get(marketId);
        (uint256 cost,) = _quoteBuy(m, _loadQ(m), outcomeId, sharesOut * m.scale, m.scale, true);
        return cost + _feeOn(cost);
    }

    /// @dev Every quote above delegates to the *same* internal function the trade itself calls,
    ///      rather than recomputing the cost from the same formula.
    ///
    ///      They are algebraically identical and were not numerically identical: the public path
    ///      used `LsLmsr.costToBuy` + `LsLmsr.prices`, which each recompute `C(q)` internally,
    ///      while the trade uses `pricesAndCost` once and derives both from the cached `c0`. The
    ///      fixed-point rounding differs, and on a live book that showed up as a quote 13 base
    ///      units below what `buy` actually charged — enough to revert every trade whose `maxCost`
    ///      came from the quote, which is every trade the UI places.
    ///
    ///      Two implementations of one number will diverge. There is now one.

    /// @notice What closing a short would return, net of fees.
    ///
    /// @dev Prices the legs sequentially against a book that updates as each sells, so this is the
    ///      figure {sellComplement} will actually pay — not the sum of independent leg quotes,
    ///      which would overstate it on a skewed book.
    function quoteSellComplement(uint256 marketId, uint256 outcomeId, uint256 sharesIn)
        external
        view
        returns (uint256 proceeds)
    {
        Market storage m = _get(marketId);
        uint256 scale = m.scale;
        uint256[] memory qWad = _loadQ(m);
        uint256 n = m.outcomeCount;

        for (uint256 j; j < n; ++j) {
            if (j == outcomeId) continue;
            (uint256 legGross,) = _quoteSell(m, qWad, j, sharesIn * scale, scale);
            proceeds += legGross - _feeOn(legGross);
            qWad[j] -= sharesIn * scale;
        }
    }

    /// @notice The fee this engine would charge on `amount`, at the current rate.
    ///
    /// @dev Exists so the frontend can show a breakdown without reimplementing the rounding rule.
    ///      The quotes above are already fee-inclusive — {quoteBuy} is what a trader pays and
    ///      {quoteSell} is what they receive — because a quote that excluded the fee would price
    ///      every screen in the app slightly wrong, and a `maxCost` derived from it would revert.
    function feeOn(uint256 amount) external view returns (uint256) {
        return _feeOn(amount);
    }

    function quoteSell(uint256 marketId, uint256 outcomeId, uint256 sharesIn)
        external
        view
        returns (uint256)
    {
        Market storage m = _get(marketId);
        (uint256 gross,) = _quoteSell(m, _loadQ(m), outcomeId, sharesIn * m.scale, m.scale);
        return gross - _feeOn(gross);
    }

    function sharesOf(uint256 marketId, address account, uint256 outcomeId) external view returns (uint256) {
        return _get(marketId).shares[account][outcomeId];
    }

    function outcomeShares(uint256 marketId, uint256 outcomeId) external view returns (uint256) {
        return _get(marketId).q[outcomeId];
    }

    function collateralOf(uint256 marketId) external view returns (uint256) {
        return _get(marketId).collateralHeld;
    }

    /// @notice Whether this market has already reached a terminal state, resolved or voided.
    ///
    /// @dev Read by {OptimisticResolver} before it accepts a bond. Without it, a market settled by
    ///      some other route would still accept proposals whose settlement step could never succeed,
    ///      locking the bond until the abandon timeout. One boolean turns that trap into a revert.
    function isSettled(uint256 marketId) external view returns (bool) {
        return _get(marketId).status != MarketTypes.Status.Trading;
    }

    /// @inheritdoc IMarketEngine
    function closeTimeOf(uint256 marketId) external view returns (uint64) {
        return _get(marketId).closeTime;
    }

    /// @inheritdoc IMarketEngine
    function outcomeCountOf(uint256 marketId) external view returns (uint32) {
        return _get(marketId).outcomeCount;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _get(uint256 marketId) internal view returns (Market storage m) {
        if (marketId >= marketCount) revert MarketNotFound(marketId);
        m = markets[marketId];
    }

    /// @dev Creation is split across three helpers purely so it compiles: an eleven-field event plus
    ///      the config locals overflows the stack under the non-IR pipeline this repo builds with.

    function _validateAndScale(CreateParams calldata p) private view returns (uint256 scale) {
        if (p.collateral == address(0) || p.resolver == address(0)) revert ZeroAddress();
        if (p.outcomeCount < MIN_OUTCOMES || p.outcomeCount > MAX_OUTCOMES) {
            revert InvalidOutcomeCount(p.outcomeCount, MIN_OUTCOMES, MAX_OUTCOMES);
        }
        if (p.closeTime <= block.timestamp) revert CloseTimeInPast(p.closeTime, uint64(block.timestamp));
        // `0` means "open now". Anything else must be in the future and before the close, so a
        // market can never be published already shut, nor open after it has stopped taking bets.
        if (p.startTime != 0 && (p.startTime >= p.closeTime || p.startTime < block.timestamp)) {
            revert InvalidStartTime(p.startTime, p.closeTime);
        }
        // The commitment and the copy are checked against each other exactly once, here, and the
        // copy is then unforgeable: it is in the calldata of this transaction forever.
        bytes32 published = keccak256(bytes(p.metadata));
        if (published != p.metadataHash) revert MetadataMismatch(published, p.metadataHash);
        if (p.alpha < MIN_ALPHA || p.alpha > MAX_ALPHA) {
            revert AlphaOutOfRange(p.alpha, MIN_ALPHA, MAX_ALPHA);
        }
        if (p.sStar > MAX_S_STAR) revert DampingOutOfRange(p.sStar, MAX_S_STAR);

        uint256 decimals = IERC20Metadata(p.collateral).decimals();
        if (decimals > MAX_COLLATERAL_DECIMALS) revert UnsupportedCollateral();
        scale = 10 ** (MAX_COLLATERAL_DECIMALS - decimals);

        uint256 totalWad = uint256(p.outcomeCount) * p.seedPerOutcome * scale;
        if (totalWad < MIN_TOTAL_SHARES_WAD) revert SeedTooSmall(totalWad, MIN_TOTAL_SHARES_WAD);
    }

    function _writeConfig(uint256 marketId, CreateParams calldata p, uint256 scale) private {
        Market storage m = markets[marketId];
        m.collateral = p.collateral;
        m.resolver = p.resolver;
        m.creator = msg.sender;
        m.createdAt = uint64(block.timestamp);
        // Resolved rather than stored as a sentinel, so every reader sees a real instant and no
        // caller has to know that zero means now.
        m.startTime = p.startTime == 0 ? uint64(block.timestamp) : p.startTime;
        m.closeTime = p.closeTime;
        m.outcomeCount = p.outcomeCount;
        m.scale = scale;
        m.alpha = p.alpha;
        m.sStar = p.sStar;
        m.seed = p.seedPerOutcome;
        m.category = p.category;
        m.metadataHash = p.metadataHash;
        m.status = MarketTypes.Status.Trading;
    }

    /// @dev Charges the creator `C(q_seed)`. `C(0) = 0`, so that is the whole cost — there is no
    ///      prior state to subtract and no protocol money at risk.
    function _seedBook(uint256 marketId, CreateParams calldata p, uint256 scale)
        private
        returns (uint256 seedCost)
    {
        Market storage m = markets[marketId];
        uint256[] memory qWad = new uint256[](p.outcomeCount);
        for (uint256 i; i < p.outcomeCount; ++i) {
            m.q[i] = p.seedPerOutcome;
            qWad[i] = p.seedPerOutcome * scale;
        }
        seedCost = _toUnitsUp(LsLmsr.cost(qWad, p.alpha, p.sStar), scale);
        _pullExact(p.collateral, msg.sender, seedCost);
        m.collateralHeld = seedCost;
        _assertSolvent(m, qWad, scale);
    }

    /// @dev Shared preconditions for every trading entry point.
    function _tradable(uint256 marketId, uint256 outcomeId, uint256 shares)
        internal
        view
        returns (Market storage m)
    {
        m = _get(marketId);
        if (m.status != MarketTypes.Status.Trading) revert MarketNotTrading(marketId);
        // Before the open and after the close are different refusals: one is "not yet" and the
        // other is "never again", and a trader can act on the difference.
        if (block.timestamp < m.startTime) revert MarketNotOpenYet(marketId, m.startTime);
        if (block.timestamp >= m.closeTime) revert MarketClosed(marketId);
        if (outcomeId >= m.outcomeCount) revert InvalidOutcome(outcomeId, m.outcomeCount);
        if (shares == 0) revert AmountZero();
        // Bounded so `shares * scale` cannot overflow and stays inside {LsLmsr.MAX_Q}.
        if (shares > LsLmsr.MAX_Q / m.scale) revert AmountTooLarge(shares, LsLmsr.MAX_Q / m.scale);
    }

    /// @dev `q` in WAD, ready for {LsLmsr}.
    function _loadQ(Market storage m) internal view returns (uint256[] memory q) {
        uint256 n = m.outcomeCount;
        uint256 scale = m.scale;
        q = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            q[i] = m.q[i] * scale;
        }
    }

    /// @notice `φ = 0.005 + 0.015·(1 − τ/T) + 0.010·|pᵢ − 1/n|`.
    ///
    /// @dev Widens as resolution approaches and as the outcome moves away from uniform — the two
    ///      moments a market maker is most exposed to someone knowing more than the curve does.
    ///      Applied outside `C`, so path independence is untouched.
    ///
    ///      For a short, `pᵢ` is the price of the outcome being shorted rather than of the basket:
    ///      shorting `i` is a directional view on `i`, and the informational risk is the same one.
    function _spreadWad(Market storage m, uint256 outcomeId, uint256[] memory qWad)
        internal
        view
        returns (uint256)
    {
        return _spreadFrom(m, outcomeId, LsLmsr.prices(qWad, m.alpha, m.sStar));
    }

    /// @dev Charge and spread for a purchase, from one fused pass over the curve.
    ///
    ///      A separate function purely to stay inside the stack limit — `buy` and `buyComplement`
    ///      each hold a market, a scale, a `q` vector, a price vector, a cost and a spread, which
    ///      is past what the EVM can address without `via_ir`. This repo decomposes instead of
    ///      enabling it: the optimiser's IR pipeline changes codegen everywhere, and that is not a
    ///      change to make for one function's convenience.
    function _quoteBuy(
        Market storage m,
        uint256[] memory qWad,
        uint256 outcomeId,
        uint256 sharesWad,
        uint256 scale,
        bool complement
    ) private view returns (uint256 charged, uint256 spread) {
        (uint256[] memory p, SD59x18 c0) = LsLmsr.pricesAndCost(qWad, m.alpha, m.sStar);
        spread = _spreadFrom(m, outcomeId, p);
        uint256 base = complement
            ? LsLmsr.costToBuyComplementFrom(c0, qWad, m.alpha, m.sStar, outcomeId, sharesWad)
            : LsLmsr.costToBuyFrom(c0, qWad, m.alpha, m.sStar, outcomeId, sharesWad);
        charged = _toUnitsUp(_withSpreadUp(base, spread), scale);
    }

    /// @dev Proceeds and spread for a sale, from one fused pass. See {_quoteBuy}.
    function _quoteSell(
        Market storage m,
        uint256[] memory qWad,
        uint256 outcomeId,
        uint256 sharesWad,
        uint256 scale
    ) private view returns (uint256 proceeds, uint256 spread) {
        (uint256[] memory p, SD59x18 c0) = LsLmsr.pricesAndCost(qWad, m.alpha, m.sStar);
        spread = _spreadFrom(m, outcomeId, p);
        proceeds = _toUnitsDown(
            _withSpreadDown(
                LsLmsr.proceedsToSellFrom(c0, qWad, m.alpha, m.sStar, outcomeId, sharesWad), spread
            ),
            scale
        );
    }

    /// @dev The spread, from a price vector the caller already has.
    ///
    ///      Split out because every trade needs `C(q)` as well as `p`, and {LsLmsr.pricesAndCost}
    ///      produces both from one pass over the exponentials. Re-deriving `p` here would put
    ///      that pass back and undo the saving.
    function _spreadFrom(Market storage m, uint256 outcomeId, uint256[] memory p)
        internal
        view
        returns (uint256)
    {
        _assertPriceSum(p);

        uint256 timeTerm = PHI_TIME;
        uint256 closeTime = m.closeTime;
        if (block.timestamp < closeTime) {
            uint256 duration = closeTime - m.createdAt;
            uint256 tau = closeTime - block.timestamp;
            uint256 remaining = tau >= duration ? WAD : (tau * WAD) / duration;
            timeTerm = (PHI_TIME * (WAD - remaining)) / WAD;
        }

        uint256 uniform = WAD / m.outcomeCount;
        uint256 pi = p[outcomeId];
        uint256 dev = pi > uniform ? pi - uniform : uniform - pi;

        return PHI_BASE + timeTerm + (PHI_SKEW * dev) / WAD;
    }

    function _withSpreadUp(uint256 base, uint256 spread) internal pure returns (uint256) {
        // Round the surcharge up: the trader pays the ceiling, never the floor.
        return base + (base * spread + WAD - 1) / WAD;
    }

    function _withSpreadDown(uint256 base, uint256 spread) internal pure returns (uint256) {
        uint256 cut = (base * spread + WAD - 1) / WAD;
        return base > cut ? base - cut : 0;
    }

    /// @dev WAD -> collateral base units. Charges round up so the market is never short-changed.
    function _toUnitsUp(uint256 wad, uint256 scale) internal pure returns (uint256) {
        return (wad + scale - 1) / scale;
    }

    /// @dev WAD -> collateral base units. Payouts round down, for the same reason.
    function _toUnitsDown(uint256 wad, uint256 scale) internal pure returns (uint256) {
        return wad / scale;
    }

    /// @notice The invariant that makes this engine safe to put real money in.
    ///
    /// @dev Re-derived from storage after every state change rather than inferred from the curve.
    ///      `C(q) − max(qᵢ)` vanishes as a book approaches certainty, so beyond that point the
    ///      mathematics stops providing a margin and only this check stands between a rounding
    ///      defect and an unpayable winner.
    function _assertSolvent(Market storage m, uint256[] memory qWad, uint256 scale) internal view {
        uint256 owedWad;
        uint256 totalWad;
        for (uint256 i; i < qWad.length; ++i) {
            totalWad += qWad[i];
            if (qWad[i] > owedWad) owedWad = qWad[i];
        }
        // Compared in base units, where both sides are exact integers.
        if (m.collateralHeld < owedWad / scale) revert Insolvent(m.collateralHeld, owedWad / scale);
        // `s` can only fall by selling, and the locked seed is not sellable, so this should be
        // unreachable. Asserted anyway: below the floor `b'` diverges and quotes stop being sane.
        if (totalWad < MIN_TOTAL_SHARES_WAD) revert SeedTooSmall(totalWad, MIN_TOTAL_SHARES_WAD);
    }

    /// @dev Last line of defence against a fixed-point defect letting someone assemble a complete
    ///      set below par and redeem it at par. Guaranteed by `b' > 0`, and checked regardless —
    ///      it rides along on the price vector the spread already needed, so it costs nothing extra.
    function _assertPriceSum(uint256[] memory p) internal pure {
        uint256 sum;
        for (uint256 i; i < p.length; ++i) {
            sum += p[i];
        }
        if (sum < WAD) revert PriceSumBelowOne(sum);
    }

    // -------------------------------------------------------------------------
    // Relay context
    // -------------------------------------------------------------------------
    //
    // `Context` is reached twice — once through {AccessControl}/{Pausable}, once through
    // {ERC2771Context} — so Solidity requires these three to be disambiguated explicitly. Each
    // resolves to the {ERC2771Context} implementation, which is the whole point: `_msgSender()` must
    // be the trader who signed, not the forwarder that delivered.

    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }

    /// @dev The fee on `amount`, rounded up — consistent with every other charge in this contract,
    ///      which rounds in the market's favour so no path can be nudged into a shortfall by
    ///      accumulated truncation. Rounding up is only ever material on amounts small enough to be
    ///      rejected by {minTradeCost} anyway.
    function _feeOn(uint256 amount) internal view returns (uint256) {
        uint16 bps = tradeFeeBps;
        if (bps == 0) return 0;
        return (amount * bps + 9_999) / 10_000;
    }

    /// @dev Refuse a trade from an account arbitration found to have lied about an outcome.
    ///
    ///      Checked on all four trading entry points and on none of the settlement ones. {redeem} in
    ///      particular stays open: the penalty is the forfeited bond and the loss of access, not the
    ///      seizure of a position that was won before the lie. See {TradingBlocklist}.
    ///
    ///      Read before the quote rather than after, so a banned account pays the revert immediately
    ///      instead of after the engine has done the expensive part of the work.
    function _assertAllowed(address trader) internal view {
        ITradingBlocklist list = blocklist;
        if (address(list) != address(0) && list.isBanned(trader)) revert AccountBanned(trader);
    }

    /// @dev The gas-abuse floor. See {minTradeCost}.
    function _assertAboveMinimum(address token, uint256 amount) internal view {
        uint256 minimum = minTradeCost[token];
        if (amount < minimum) revert AmountBelowMin(amount, minimum);
    }

    /// @dev Book a fee against a token, outside market collateral.
    ///
    ///      Note what the caller must always have done first: added only the trade's *cost* to
    ///      `collateralHeld`, and moved `netContributed` by that same cost rather than by what the
    ///      trader actually paid. That keeps `sumPositiveNet ≤ collateralHeld` an identity rather than
    ///      a hope — if a fee were counted as contribution, a voided market would owe refunds it had
    ///      never been paid, and {invalidate} would revert as insolvent with traders' money inside.
    ///
    ///      The visible consequence: a voided market refunds cost basis, not fees. Fees were earned
    ///      on trades that did execute, and solvency leaves no alternative.
    function _accrueFee(uint256 marketId, address token, address trader, uint256 fee) internal {
        if (fee == 0) return;
        feesAccrued[token] += fee;
        feesOf[marketId] += fee;
        emit FeeCharged(marketId, trader, fee);
    }

    /// @dev Collateral must arrive exactly. A fee-on-transfer or rebasing token would silently
    ///      under-fund the market and break the solvency argument at the first trade.
    function _pullExact(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert UnsupportedCollateral();
    }

    /// @dev Track cost basis for fair refunds if the market is voided.
    function _addContribution(Market storage m, address user, int256 delta) internal {
        int256 previous = m.netContributed[user];
        int256 next = previous + delta;
        m.netContributed[user] = next;

        uint256 wasPositive = previous > 0 ? uint256(previous) : 0;
        uint256 isPositive = next > 0 ? uint256(next) : 0;
        m.sumPositiveNet = m.sumPositiveNet + isPositive - wasPositive;
    }
}

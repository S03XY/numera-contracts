// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @dev The only functions this forwarder will ever relay. Declared as an interface rather than
///      hardcoded selector literals so the compiler derives them, and a signature change upstream
///      is a build error instead of a silently dead allowlist entry.
interface INumeraRelayable {
    function buy(uint256 marketId, uint256 outcomeId, uint256 sharesOut, uint256 maxCost)
        external
        returns (uint256);
    function buyComplement(uint256 marketId, uint256 outcomeId, uint256 sharesOut, uint256 maxCost)
        external
        returns (uint256);
    function sell(uint256 marketId, uint256 outcomeId, uint256 sharesIn, uint256 minRefund)
        external
        returns (uint256);
    function sellComplement(uint256 marketId, uint256 outcomeId, uint256 sharesIn, uint256 minRefund)
        external
        returns (uint256);
    function redeem(uint256 marketId) external returns (uint256);
}

/// @title NumeraForwarder
/// @notice The one contract allowed to speak for a trader's market account, so that account never
///         needs a single wei of native gas.
///
/// @dev ## Why gas sponsorship is a privacy problem, not a convenience problem
///
/// Numera hides *who* is trading by giving every (user, market) pair its own derived address. That
/// address is `msg.sender` at the engine, and it is funded by a shielded-pool withdrawal whose
/// source account is private. The link is broken exactly as long as nothing public ever connects
/// the user to the account.
///
/// Native gas is what breaks it. If the user's own wallet sends the account even dust for gas, that
/// transfer is public and permanent, and it retroactively deanonymises every position the account
/// will ever hold. An authenticated "fund my account" endpoint fails the same way from the other
/// side: our own logs would then hold the mapping the design exists to destroy.
///
/// So the account signs and never sends. It holds zero native balance for its whole life, and the
/// question "where does its gas come from" stops existing.
///
/// ## Why the relayer cannot be authenticated, and what replaces authentication
///
/// A request carries a signature and nothing else — no cookie, no token, no user id — because any
/// identifier we accepted would reconstruct the user↔account link on our own infrastructure. That
/// rules out the obvious defence against gas theft, so the defences here are **structural** and
/// **economic** instead, and they are strictly stronger for it: they hold against an attacker who
/// has stolen the relayer's key outright.
///
///  1. **One destination, frozen.** {market} is set once by the deployer and can never change.
///     There is no code path from here to any other contract, so this can never be used as a
///     general-purpose relayer no matter who is driving it.
///  2. **Five functions.** {isRelayable} allows `buy`, `buyComplement`, `sell`, `sellComplement`
///     and `redeem` — the complete set a trader needs and nothing else. Market creation, by far
///     the most expensive call on the engine and the one that moves seed capital, is unreachable,
///     as is every admin and resolver path.
///  3. **A forwarded-gas ceiling.** {MAX_RELAY_GAS} bounds what one request can demand.
///  4. **No native value, ever.** The engine is not payable and this refuses to pretend otherwise.
///
/// What is deliberately *not* here: rate limiting, spend caps and simulation. Those bound cost
/// rather than capability, they need mutable state and off-chain context, and putting them on chain
/// would add a privileged switch to a contract whose value is that it has none. They live in the
/// relayer service. The on-chain half is the part that must survive that service being compromised.
///
/// ## The residual, stated plainly
///
/// An attacker holding real collateral can still make trades whose fee barely covers their gas. No
/// signature check can stop that, because those are indistinguishable from real trades — they *are*
/// real trades. The bound is economic: the engine's minimum trade size is set so every relayable
/// operation carries a fee worth several times its own gas, which makes the attack cost more than
/// it inflicts. See `LsLmsrMarket.minTradeCost`.
contract NumeraForwarder is ERC2771Forwarder {
    /// @notice Ceiling on the gas one request may ask to have forwarded.
    ///
    /// @dev A measured buy costs ~297k gas end to end, and a four-outcome `buyComplement` — the
    ///      heaviest relayable call — stays well inside this. Generous on purpose: too tight a cap
    ///      rejects honest trades, and this is not the mechanism that controls spend. On Monad the
    ///      *transaction* gas limit is billed rather than the gas used, so the relayer's own limit
    ///      is what actually determines cost; this only stops a request demanding an absurd
    ///      forward. Both halves are needed.
    uint256 public constant MAX_RELAY_GAS = 1_000_000;

    /// @notice The collateral token, and the only contract whose `permit` this will submit.
    address public immutable collateral;

    /// @notice The only address whose {initialize} call is accepted.
    address public immutable initializer;

    /// @notice The one and only contract this forwarder will relay to.
    /// @dev Frozen after {initialize}. Not a constructor immutable purely because of a deployment
    ///      cycle: the engine needs this forwarder's address to trust it, and this needs the
    ///      engine's address to target it. One of the two has to be wired second.
    address public market;

    error AlreadyInitialized();
    error NotInitializer(address caller);
    error NotInitialized();
    error TargetNotAllowed(address to);
    error SelectorNotAllowed(bytes4 selector);
    error ValueNotAllowed(uint256 value);
    error GasCapExceeded(uint256 requested, uint256 cap);
    error CalldataTooShort(uint256 length);
    error BatchNotSupported();
    error PermitTargetNotAllowed(address token);
    error ZeroAddress();

    event Initialized(address indexed market);

    constructor(address collateral_, address initializer_) ERC2771Forwarder("Numera Forwarder") {
        if (collateral_ == address(0) || initializer_ == address(0)) revert ZeroAddress();
        collateral = collateral_;
        initializer = initializer_;
    }

    /// @notice Freeze the single relay destination. Callable once, by the deployer, and never again.
    ///
    /// @dev Gated on {initializer} rather than left open, because an unguarded one-shot setter can
    ///      be front-run between deployment and wiring — and whoever won that race would own a
    ///      forwarder pointed at a contract of their choosing.
    function initialize(address market_) external {
        if (msg.sender != initializer) revert NotInitializer(msg.sender);
        if (market != address(0)) revert AlreadyInitialized();
        if (market_ == address(0)) revert ZeroAddress();
        market = market_;
        emit Initialized(market_);
    }

    /// @notice Whether this forwarder will ever relay `selector`.
    ///
    /// @dev Public so the relayer and the frontend check the same rule the chain enforces, instead
    ///      of keeping a second copy of it that can drift.
    function isRelayable(bytes4 selector) public pure returns (bool) {
        return selector == INumeraRelayable.buy.selector
            || selector == INumeraRelayable.buyComplement.selector
            || selector == INumeraRelayable.sell.selector
            || selector == INumeraRelayable.sellComplement.selector
            || selector == INumeraRelayable.redeem.selector;
    }

    /// @inheritdoc ERC2771Forwarder
    /// @dev Every structural check runs before any signature work, so a malformed request is
    ///      rejected as cheaply as possible.
    function execute(ForwardRequestData calldata request) public payable override {
        _assertRelayable(request);
        super.execute(request);
    }

    /// @notice Approve the engine and trade, in one transaction.
    ///
    /// @dev A market account cannot call `approve` — that would need gas it will never have — so the
    ///      allowance is set by an EIP-2612 signature the account produces off chain. Bundling it
    ///      with the trade means a trader's first bet is one transaction rather than two, and there
    ///      is no window in which an allowance exists for a trade that never happened.
    ///
    ///      `permit` is permissionless by design: anyone may submit a valid signature. That is what
    ///      makes it usable here, and it is why this is the only place a permit is ever relayed —
    ///      a standalone permit endpoint would let a stranger have us pay for their approvals.
    ///      Bundled, a permit costs an attacker a trade they must also fund.
    function executeWithPermit(
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        ForwardRequestData calldata request
    ) external {
        _assertRelayable(request);
        // Named `collateral` rather than taken as a parameter: a token address from the caller is a
        // free call to an arbitrary contract, which is exactly what the single-target rule forbids.
        IERC20Permit(collateral).permit(owner, market, value, deadline, v, r, s);
        super.execute(request);
    }

    /// @inheritdoc ERC2771Forwarder
    /// @dev Unsupported. Batching adds partial-failure and value-refund behaviour to a contract
    ///      whose whole purpose is to have as little behaviour as possible, and the saving is one
    ///      base fee per trade. If throughput ever needs it, add a batch that reuses
    ///      {_assertRelayable} on every entry rather than relaxing anything here.
    function executeBatch(ForwardRequestData[] calldata, address payable) public payable override {
        revert BatchNotSupported();
    }

    /// @notice Whether a request passes both this contract's rules and the ERC-2771 checks.
    /// @dev For the relayer's pre-flight: it should drop a request it can predict will fail rather
    ///      than pay for the revert.
    function verifyRelayable(ForwardRequestData calldata request) external view returns (bool) {
        if (market == address(0) || request.to != market) return false;
        if (request.value != 0 || request.gas > MAX_RELAY_GAS) return false;
        if (request.data.length < 4 || !isRelayable(bytes4(request.data[:4]))) return false;
        return verify(request);
    }

    function _assertRelayable(ForwardRequestData calldata request) internal view {
        address target = market;
        if (target == address(0)) revert NotInitialized();
        if (request.to != target) revert TargetNotAllowed(request.to);
        // The engine is not payable, and a forwarder that can carry value is a forwarder that can
        // be drained.
        if (request.value != 0) revert ValueNotAllowed(request.value);
        if (request.gas > MAX_RELAY_GAS) revert GasCapExceeded(request.gas, MAX_RELAY_GAS);
        if (request.data.length < 4) revert CalldataTooShort(request.data.length);

        bytes4 selector = bytes4(request.data[:4]);
        if (!isRelayable(selector)) revert SelectorNotAllowed(selector);
    }
}

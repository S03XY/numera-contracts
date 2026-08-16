// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @dev The only functions this forwarder will ever relay. Declared as an interface rather than
///      hardcoded selector literals so the compiler derives them, and a signature change upstream
///      is a build error instead of a silently dead allowlist entry.
interface IResolutionRelayable {
    function propose(address market, uint256 marketId, uint256 outcomeId) external;
    function dispute(address market, uint256 marketId, uint256 counterOutcomeId) external;
}

/// @title ResolutionForwarder
/// @notice Lets a trader's market account propose or dispute an outcome without ever holding gas.
///
/// @dev ## Why resolution needs its own forwarder
///
/// {NumeraForwarder} is frozen to the engine and relays five trading selectors. That is not a
/// limitation to route around: a forwarder whose target can change, or whose allowlist can grow, is
/// a general-purpose relayer wearing a costume. So resolution gets a second instance of the same
/// shape, with its own single target and its own two functions.
///
/// ## Why proposing has to be private at all
///
/// Whoever proposes an outcome is, overwhelmingly, someone holding that outcome. Proposing "Argentina
/// wins" from a login wallet tells anyone reading the chain that this wallet probably holds
/// Argentina. That is a correlation between a public identity and a shielded position, and it is
/// exactly the link the rest of the product exists to prevent. Routing the proposal through the
/// market account keeps the proposer inside the same anonymity set as the trade.
///
/// ## What replaces authentication
///
/// The same structural defences as the trading forwarder — one frozen destination, a fixed selector
/// set, a gas ceiling, no native value — plus a stronger economic one.
///
/// Every function relayable here **posts a bond in the same transaction**. A spammer does not merely
/// have to make a request that looks real; they have to lock collateral worth many times the gas
/// they are costing us, and they only get it back by being right. The trading forwarder's residual
/// risk — an attacker making genuine minimum-size trades — has no counterpart here, because there is
/// no such thing as a free proposal.
///
/// The resolver's one bond-free path, a proposal by a `RESOLVER_ROLE` holder, does not weaken that.
/// It is bond-free because of *who signed it*, and only the operator's own wallets can produce that
/// signature. A stranger relaying somebody else's request still cannot make one that costs nothing.
///
/// `finalize` is deliberately **not** relayable. It moves an already-agreed outcome on chain and
/// pays a reward to whoever is on record as the proposer, so the caller is not the beneficiary and
/// has nothing to hide. Anyone may call it directly, and it stays a public maintenance action.
contract ResolutionForwarder is ERC2771Forwarder {
    /// @notice Ceiling on the gas one request may ask to have forwarded.
    ///
    /// @dev Proposing is a token transfer plus one struct write, an order of magnitude below a
    ///      trade. On Monad the transaction gas limit is billed rather than the gas used, so the
    ///      relayer's own limit is what determines cost; this only stops a request demanding an
    ///      absurd forward.
    uint256 public constant MAX_RELAY_GAS = 500_000;

    /// @notice The collateral token, and the only contract whose `permit` this will submit.
    address public immutable collateral;

    /// @notice The only address whose {initialize} call is accepted.
    address public immutable initializer;

    /// @notice The one and only contract this forwarder will relay to.
    /// @dev Frozen after {initialize}. Deferred out of the constructor for the same reason as the
    ///      trading forwarder: the resolver must trust this address, and this must target the
    ///      resolver, so one of the two is wired second.
    address public resolver;

    error AlreadyInitialized();
    error NotInitializer(address caller);
    error NotInitialized();
    error TargetNotAllowed(address to);
    error SelectorNotAllowed(bytes4 selector);
    error ValueNotAllowed(uint256 value);
    error GasCapExceeded(uint256 requested, uint256 cap);
    error CalldataTooShort(uint256 length);
    error BatchNotSupported();
    error ZeroAddress();

    event Initialized(address indexed resolver);

    constructor(address collateral_, address initializer_) ERC2771Forwarder("Numera Resolution Forwarder") {
        if (collateral_ == address(0) || initializer_ == address(0)) revert ZeroAddress();
        collateral = collateral_;
        initializer = initializer_;
    }

    /// @notice Freeze the single relay destination. Callable once, by the deployer, and never again.
    /// @dev Gated on {initializer} rather than left open, because an unguarded one-shot setter can
    ///      be front-run between deployment and wiring.
    function initialize(address resolver_) external {
        if (msg.sender != initializer) revert NotInitializer(msg.sender);
        if (resolver != address(0)) revert AlreadyInitialized();
        if (resolver_ == address(0)) revert ZeroAddress();
        resolver = resolver_;
        emit Initialized(resolver_);
    }

    /// @notice Whether this forwarder will ever relay `selector`.
    /// @dev Public so the relayer and the frontend check the same rule the chain enforces, instead
    ///      of keeping a second copy of it that can drift.
    function isRelayable(bytes4 selector) public pure returns (bool) {
        return selector == IResolutionRelayable.propose.selector
            || selector == IResolutionRelayable.dispute.selector;
    }

    /// @inheritdoc ERC2771Forwarder
    function execute(ForwardRequestData calldata request) public payable override {
        _assertRelayable(request);
        super.execute(request);
    }

    /// @notice Approve the resolver and post a bond, in one transaction.
    ///
    /// @dev A market account cannot call `approve` — that would need gas it will never have — so the
    ///      allowance comes from an EIP-2612 signature the account produces off chain. Bundling it
    ///      with the bonded call means there is never an allowance sitting behind a proposal that
    ///      was never made.
    ///
    ///      As in the trading forwarder, `collateral` is an immutable rather than a parameter: a
    ///      token address supplied by the caller is a free call to an arbitrary contract, which is
    ///      what the single-target rule exists to forbid.
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
        IERC20Permit(collateral).permit(owner, resolver, value, deadline, v, r, s);
        super.execute(request);
    }

    /// @inheritdoc ERC2771Forwarder
    /// @dev Unsupported, for the same reason as the trading forwarder: batching adds partial-failure
    ///      and value-refund behaviour to a contract whose whole purpose is to have as little
    ///      behaviour as possible.
    function executeBatch(ForwardRequestData[] calldata, address payable) public payable override {
        revert BatchNotSupported();
    }

    /// @notice Whether a request passes both this contract's rules and the ERC-2771 checks.
    /// @dev For the relayer's pre-flight: it should drop a request it can predict will fail rather
    ///      than pay for the revert.
    function verifyRelayable(ForwardRequestData calldata request) external view returns (bool) {
        if (resolver == address(0) || request.to != resolver) return false;
        if (request.value != 0 || request.gas > MAX_RELAY_GAS) return false;
        if (request.data.length < 4 || !isRelayable(bytes4(request.data[:4]))) return false;
        return verify(request);
    }

    function _assertRelayable(ForwardRequestData calldata request) internal view {
        address target = resolver;
        if (target == address(0)) revert NotInitialized();
        if (request.to != target) revert TargetNotAllowed(request.to);
        if (request.value != 0) revert ValueNotAllowed(request.value);
        if (request.gas > MAX_RELAY_GAS) revert GasCapExceeded(request.gas, MAX_RELAY_GAS);
        if (request.data.length < 4) revert CalldataTooShort(request.data.length);

        bytes4 selector = bytes4(request.data[:4]);
        if (!isRelayable(selector)) revert SelectorNotAllowed(selector);
    }
}

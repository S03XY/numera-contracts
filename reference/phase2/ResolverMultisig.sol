// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ZeroAddress} from "../libraries/Errors.sol";

/// @title ResolverMultisig
/// @notice An m-of-n signer set that settles markets, with the operator deciding who is on it.
///
/// @dev ## Two separate questions, two separate authorities
///
/// **Who may settle** is the operator's call. `DEFAULT_ADMIN_ROLE` adds and removes signers, moves
/// the threshold, and chooses which contracts the set may speak to. Membership is not something a
/// stranger can acquire, and not something the signers can grant each other.
///
/// **What gets settled** is the signers' call. Only they may raise a proposal, and it executes when
/// {threshold} of them agree. The operator has no vote unless they are also a signer, which is an
/// explicit `addSigner` and therefore visible on chain rather than implied.
///
/// The honest consequence: an operator who can reshape the set can, in principle, reduce it to one
/// wallet and settle alone. So this quorum defends against a signer going rogue, not against the
/// operator. That is the intended trust model for Numera, where the operator is the accountable
/// party in any case, and it is stated here rather than left for a reader to discover.
///
/// ## Scope
///
/// A proposal may only call a contract the admin has adopted with {addTarget}. The set is explicit
/// and readable, so "what can this quorum touch" is a single call rather than an audit. Settlement
/// contracts belong here; the engine, factory and forwarder deliberately do not.
///
/// ## One open proposal per action
///
/// Proposals are keyed by `keccak256(epoch, target, keccak256(data))`, so two signers who raise the
/// same settlement independently land on one proposal instead of deadlocking at one confirmation
/// each. Read {pendingProposal} before proposing.
///
/// ## Changing the signer set voids in-flight approvals
///
/// {signerEpoch} bumps whenever a signer is added or removed, and a proposal may only be confirmed
/// or executed in the epoch it was raised in. Without that, a since-removed signer's confirmation
/// would keep counting toward a quorum they are no longer part of.
contract ResolverMultisig is AccessControl {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @dev `target`/`epoch`/`confirmations` share one slot; the flags and proposer share the next.
    struct Proposal {
        address target;
        uint64 epoch;
        uint32 confirmations;
        address proposer;
        bool executed;
        bool cancelled;
        bytes data;
    }

    /// @notice A proposal as the UI needs it, without exposing storage layout.
    struct ProposalView {
        uint256 id;
        address target;
        bytes data;
        address proposer;
        uint64 epoch;
        uint32 confirmations;
        bool executed;
        bool cancelled;
        /// @dev False once the signer set has changed under it; such a proposal must be re-raised.
        bool current;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 threshold);
    event TargetAdded(address indexed target);
    event TargetRemoved(address indexed target);
    event Proposed(
        uint256 indexed id, address indexed proposer, address indexed target, uint64 epoch, bytes data
    );
    event Confirmed(uint256 indexed id, address indexed signer, uint32 confirmations);
    event Revoked(uint256 indexed id, address indexed signer, uint32 confirmations);
    event Cancelled(uint256 indexed id, address indexed signer);
    event Executed(uint256 indexed id, address indexed executor);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotSigner(address caller);
    error NotProposer(address caller);
    error AlreadySigner(address signer);
    error UnknownSigner(address signer);
    error InvalidThreshold(uint256 threshold, uint256 signers);
    error NoSigners();
    error UnknownProposal(uint256 id);
    error ProposalClosed(uint256 id);
    error ProposalStale(uint256 id);
    error ProposalOpen(uint256 id);
    error AlreadyConfirmed(uint256 id, address signer);
    error NotConfirmed(uint256 id, address signer);
    error QuorumNotReached(uint32 confirmations, uint256 threshold);
    error TargetNotAllowed(address target);
    error AlreadyTarget(address target);
    error CallFailed(bytes reason);

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Confirmations required to execute.
    uint256 public threshold;

    /// @notice Bumped on every signer-set change; proposals are only valid within their own epoch.
    uint64 public signerEpoch;

    address[] private _signers;
    /// @dev 1-based index into {_signers}; 0 means "not a signer".
    mapping(address => uint256) private _signerIndex;

    address[] private _targets;
    /// @dev 1-based index into {_targets}; 0 means "not governed".
    mapping(address => uint256) private _targetIndex;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasConfirmed;

    /// @dev `keccak256(epoch, target, keccak256(data))` => id + 1, cleared when the proposal closes.
    mapping(bytes32 => uint256) private _openProposal;

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    modifier onlySigner() {
        if (_signerIndex[msg.sender] == 0) revert NotSigner(msg.sender);
        _;
    }

    /// @param admin The operator. Decides membership, the threshold, and what the set may call.
    /// @param signers_ Initial signer set; duplicates and the zero address are rejected.
    /// @param threshold_ Confirmations required, `1 <= threshold_ <= signers_.length`.
    constructor(address admin, address[] memory signers_, uint256 threshold_) {
        if (admin == address(0)) revert ZeroAddress();
        if (signers_.length == 0) revert NoSigners();
        if (threshold_ == 0 || threshold_ > signers_.length) {
            revert InvalidThreshold(threshold_, signers_.length);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i = 0; i < signers_.length; ++i) {
            _addSigner(signers_[i]);
        }
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }

    // ---------------------------------------------------------------------
    // Membership and scope — the operator's half
    // ---------------------------------------------------------------------

    function addSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addSigner(signer);
        signerEpoch += 1;
    }

    /// @dev Cannot leave the set unable to reach its own threshold, which would freeze settlement
    ///      until the admin also lowered it. Refusing is clearer than silently creating that state.
    function removeSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 index = _signerIndex[signer];
        if (index == 0) revert UnknownSigner(signer);
        if (_signers.length - 1 < threshold) revert InvalidThreshold(threshold, _signers.length - 1);

        address last = _signers[_signers.length - 1];
        _signers[index - 1] = last;
        _signerIndex[last] = index;
        _signers.pop();
        delete _signerIndex[signer];

        signerEpoch += 1;
        emit SignerRemoved(signer);
    }

    /// @dev No epoch bump: every confirmation already gathered is from a current signer, so a
    ///      threshold change does not invalidate any of them. It only moves the bar they count
    ///      against, which is the admin's decision to make.
    function setThreshold(uint256 threshold_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (threshold_ == 0 || threshold_ > _signers.length) {
            revert InvalidThreshold(threshold_, _signers.length);
        }
        threshold = threshold_;
        emit ThresholdChanged(threshold_);
    }

    /// @notice Allow the signer set to call `target`.
    /// @dev Adopting a contract is how this survives new settlement machinery without a redeploy —
    ///      `TrustedResolver` and `PrivateOptimisticResolver` are the intended entries. Keep the
    ///      engine, factory and forwarder out: a settlement quorum should not own the market.
    function addTarget(address target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (target == address(0)) revert ZeroAddress();
        if (_targetIndex[target] != 0) revert AlreadyTarget(target);
        _targets.push(target);
        _targetIndex[target] = _targets.length;
        emit TargetAdded(target);
    }

    /// @dev Open proposals against a removed target stay open but can never execute, since
    ///      {execute} re-checks. They fall away on their own rather than needing a sweep.
    function removeTarget(address target) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 index = _targetIndex[target];
        if (index == 0) revert TargetNotAllowed(target);

        address last = _targets[_targets.length - 1];
        _targets[index - 1] = last;
        _targetIndex[last] = index;
        _targets.pop();
        delete _targetIndex[target];

        emit TargetRemoved(target);
    }

    // ---------------------------------------------------------------------
    // Proposals — the signers' half
    // ---------------------------------------------------------------------

    /// @notice Raise a call for the signer set to approve, and confirm it as the proposer.
    /// @return id The proposal id. Executes within this call when the threshold is 1.
    function propose(address target, bytes calldata data) external onlySigner returns (uint256 id) {
        if (_targetIndex[target] == 0) revert TargetNotAllowed(target);

        bytes32 key = _key(signerEpoch, target, data);
        uint256 existing = _openProposal[key];
        if (existing != 0) revert ProposalOpen(existing - 1);

        id = _proposals.length;
        _proposals.push(
            Proposal({
                target: target,
                epoch: signerEpoch,
                confirmations: 0,
                proposer: msg.sender,
                executed: false,
                cancelled: false,
                data: data
            })
        );
        _openProposal[key] = id + 1;
        emit Proposed(id, msg.sender, target, signerEpoch, data);

        _confirm(id);
    }

    /// @notice Add your confirmation, executing the call if that reaches the threshold.
    function confirm(uint256 id) external onlySigner {
        _confirm(id);
    }

    /// @notice Withdraw your confirmation from a proposal that has not executed.
    function revoke(uint256 id) external onlySigner {
        Proposal storage p = _load(id);
        if (!hasConfirmed[id][msg.sender]) revert NotConfirmed(id, msg.sender);
        hasConfirmed[id][msg.sender] = false;
        p.confirmations -= 1;
        emit Revoked(id, msg.sender, p.confirmations);
    }

    /// @notice Withdraw a proposal you raised, freeing the action to be proposed again.
    /// @dev Proposer-only rather than any-signer: cancelling is otherwise a griefing lever, and a
    ///      proposal nobody confirms is inert anyway.
    function cancel(uint256 id) external {
        Proposal storage p = _load(id);
        if (msg.sender != p.proposer) revert NotProposer(msg.sender);
        p.cancelled = true;
        delete _openProposal[_key(p.epoch, p.target, p.data)];
        emit Cancelled(id, msg.sender);
    }

    /// @notice Execute a proposal that already has enough confirmations.
    /// @dev The retry path, for when the threshold moved under a proposal that had already gathered
    ///      approvals, or when the call failed for a reason that has since cleared.
    function execute(uint256 id) external onlySigner {
        Proposal storage p = _load(id);
        if (p.confirmations < threshold) revert QuorumNotReached(p.confirmations, threshold);
        _execute(id, p);
    }

    function _confirm(uint256 id) private {
        Proposal storage p = _load(id);
        if (hasConfirmed[id][msg.sender]) revert AlreadyConfirmed(id, msg.sender);
        hasConfirmed[id][msg.sender] = true;
        p.confirmations += 1;
        emit Confirmed(id, msg.sender, p.confirmations);

        if (p.confirmations >= threshold) _execute(id, p);
    }

    /// @dev A failing target call reverts the whole transaction, including the confirmation that
    ///      triggered it. That is the useful behaviour for the last signer: settling a market that
    ///      has not closed yet fails with the engine's own reason instead of silently queueing.
    function _execute(uint256 id, Proposal storage p) private {
        // Re-checked rather than trusted from proposal time: the admin may have dropped the target
        // in between, and a revoked scope has to bite on the call that matters.
        if (_targetIndex[p.target] == 0) revert TargetNotAllowed(p.target);

        p.executed = true;
        delete _openProposal[_key(p.epoch, p.target, p.data)];

        (bool ok, bytes memory ret) = p.target.call(p.data);
        if (!ok) revert CallFailed(ret);

        emit Executed(id, msg.sender);
    }

    /// @dev Every mutating path funnels through here, so open/stale/closed is checked exactly once.
    function _load(uint256 id) private view returns (Proposal storage p) {
        if (id >= _proposals.length) revert UnknownProposal(id);
        p = _proposals[id];
        if (p.executed || p.cancelled) revert ProposalClosed(id);
        if (p.epoch != signerEpoch) revert ProposalStale(id);
    }

    function _key(uint64 epoch, address target, bytes memory data) private pure returns (bytes32) {
        return keccak256(abi.encode(epoch, target, keccak256(data)));
    }

    function _addSigner(address signer) private {
        if (signer == address(0)) revert ZeroAddress();
        if (_signerIndex[signer] != 0) revert AlreadySigner(signer);
        _signers.push(signer);
        _signerIndex[signer] = _signers.length;
        emit SignerAdded(signer);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isSigner(address account) external view returns (bool) {
        return _signerIndex[account] != 0;
    }

    function signers() external view returns (address[] memory) {
        return _signers;
    }

    function signerCount() external view returns (uint256) {
        return _signers.length;
    }

    function isTarget(address target) external view returns (bool) {
        return _targetIndex[target] != 0;
    }

    /// @notice Everything this quorum is allowed to call. One read answers "what can it touch".
    function targets() external view returns (address[] memory) {
        return _targets;
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    /// @notice The open proposal for `target`/`data` in the current epoch, if there is one.
    /// @dev The frontend's pre-flight read: `exists` means confirm `id` rather than propose again.
    function pendingProposal(address target, bytes calldata data)
        external
        view
        returns (bool exists, uint256 id)
    {
        uint256 slot = _openProposal[_key(signerEpoch, target, data)];
        return (slot != 0, slot == 0 ? 0 : slot - 1);
    }

    function proposalAt(uint256 id) external view returns (ProposalView memory) {
        if (id >= _proposals.length) revert UnknownProposal(id);
        Proposal storage p = _proposals[id];
        return ProposalView({
            id: id,
            target: p.target,
            data: p.data,
            proposer: p.proposer,
            epoch: p.epoch,
            confirmations: p.confirmations,
            executed: p.executed,
            cancelled: p.cancelled,
            current: p.epoch == signerEpoch
        });
    }
}

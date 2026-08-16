// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockExecutionAccount
/// @notice Test double for an Unlink ERC-4337 `ExecutionAccount`.
/// @dev Unlink withdraws collateral from its shielded pool into a fresh (or reused) smart account,
///      which then calls target contracts. From the market's perspective, THIS contract's address
///      is `msg.sender` — never the real user, and never `tx.origin` (which would be Unlink's
///      bundler). This mock reproduces that exact call pattern:
///        - `execute(calls[])` runs a batch atomically in one "UserOperation" (e.g. approve + placeBet),
///        - it can hold ERC-20 balances (simulating `withdrawFromPool`),
///        - after a claim, funds land here and can be swept out (simulating `returnToPool`).
///      The owner gate mirrors "the owner key signs the ExecutionIntent".
contract MockExecutionAccount {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    address public owner;

    error NotOwner();
    error CallFailed(uint256 index, bytes returndata);

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Execute a batch of calls atomically, mirroring an Unlink UserOperation.
    /// @dev Reverts the whole batch if any sub-call reverts (all-or-nothing settlement).
    function execute(Call[] calldata calls) external payable returns (bytes[] memory results) {
        if (msg.sender != owner) revert NotOwner();
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
            results[i] = ret;
        }
    }

    receive() external payable {}
}

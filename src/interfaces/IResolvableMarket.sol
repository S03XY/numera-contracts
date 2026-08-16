// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IResolvableMarket
/// @notice The settlement hooks a resolver invokes on a market engine.
/// @dev A market engine restricts these to the per-market `resolver` address, allowing any
///      resolution source (EOA, multisig, {TrustedResolver}, or a custom oracle adapter) to be
///      bound per market. Kept minimal so engines and resolvers evolve independently.
interface IResolvableMarket {
    /// @notice Settle a market to a single winning outcome. Winners may then claim.
    /// @param marketId The market to settle.
    /// @param winningOutcomeId The 0-indexed winning outcome.
    function resolve(uint256 marketId, uint256 winningOutcomeId) external;

    /// @notice Void a market. Every bettor may refund their full stake.
    /// @param marketId The market to void.
    function invalidate(uint256 marketId) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMarketEngine
/// @notice Minimal, engine-agnostic surface used by the registry and the resolver.
/// @dev Both {ParimutuelMarket} and {LMSRMarket} implement these, letting off-engine contracts
///      validate a market (exists, has closed, valid outcome id) without knowing the engine type.
interface IMarketEngine {
    function marketCount() external view returns (uint256);
    function closeTimeOf(uint256 marketId) external view returns (uint64);
    function outcomeCountOf(uint256 marketId) external view returns (uint32);
}

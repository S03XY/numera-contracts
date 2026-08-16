// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ITradingBlocklist
/// @notice The two sides of {TradingBlocklist}: engines read it, resolvers write to it.
/// @dev Split into an interface so neither side has to import the other's implementation, and so a
///      replacement list only has to satisfy these two functions.
interface ITradingBlocklist {
    /// @notice Whether `account` is barred from trading.
    function isBanned(address account) external view returns (bool);

    /// @notice Bar `account`, recording which market the ruling came from.
    function ban(address account, address context, uint256 marketId) external;
}

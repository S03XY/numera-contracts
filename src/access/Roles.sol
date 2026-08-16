// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Roles
/// @notice Canonical AccessControl role identifiers used across the protocol.
library Roles {
    /// @notice May create new markets on an engine.
    bytes32 internal constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");

    /// @notice May push resolutions/invalidations through a resolver.
    ///
    /// @dev On {OptimisticResolver} this is the *bond-free* proposing right, held by the operator and
    ///      by any wallet it trusts. It is not the last word: a bond-free proposal is disputable on
    ///      exactly the same terms as a stranger's.
    bytes32 internal constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    /// @notice May rule on a disputed market. The final word on a contested outcome.
    ///
    /// @dev Deliberately separate from {RESOLVER_ROLE}: proposing is routine and wants to be quick,
    ///      arbitration is contested and wants a quorum. Held by {ResolverMultisig}, so no single
    ///      trusted wallet that proposed an outcome can also be the one that upholds it.
    bytes32 internal constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");

    /// @notice May bar a market account from opening or closing positions.
    ///
    /// @dev Held by {OptimisticResolver}, which bans the account that staked a bond on a false
    ///      outcome. An operator holds it too, for the cases arbitration does not cover.
    bytes32 internal constant BLOCKLIST_ROLE = keccak256("BLOCKLIST_ROLE");

    /// @notice May pause/unpause betting in an emergency.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice May update protocol fee parameters and the fee recipient.
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    /// @notice May curate the factory catalog: manage categories and index markets.
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
}

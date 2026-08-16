// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MarketTypes
/// @notice Shared enums used across market implementations.
library MarketTypes {
    /// @notice Resolution lifecycle of a market.
    /// @dev Trading vs. closed-for-betting is derived from `block.timestamp` vs. `closeTime`,
    ///      so this enum only tracks the *settlement* state.
    enum Status {
        Trading, // default state after creation; betting allowed until closeTime
        Resolved, // a winning outcome has been set; winners may claim
        Invalid // market voided; every bettor may refund their full stake
    }

    /// @notice Pricing engine backing a market. Kept for factory/registry tagging.
    ///
    /// @dev Appended to, never reordered: the numeric value is written into the factory's index and
    ///      read by the off-chain indexer, so renumbering would silently relabel every market that
    ///      has already been recorded.
    ///
    ///      `Parimutuel` and `LMSR` remain defined for historical records but are no longer
    ///      deployed or registered — a pooled book cannot let a trader exit before settlement, and
    ///      the plain LMSR needs a protocol-funded subsidy that the damped curve makes unnecessary.
    enum Kind {
        Parimutuel, // retired: pooled, buy-only, no exit before settlement
        LMSR, // retired: fixed `b`, requires a funded b*ln(n) subsidy
        LsLmsr // damped liquidity-sensitive LMSR: long, short and exit, self-funding
    }
}

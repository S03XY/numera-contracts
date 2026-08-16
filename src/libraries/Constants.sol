// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Constants
/// @notice Shared protocol-wide constants for the private prediction market.
library Constants {
    /// @notice Basis-point denominator (100% = 10_000 bps).
    uint256 internal constant BPS = 10_000;

    /// @notice Hard ceiling on any configurable fee (10%). Protects bettors.
    uint256 internal constant MAX_FEE_BPS = 1_000;

    /// @notice Fixed-point scalar (1e18) used for prices / implied probabilities.
    uint256 internal constant WAD = 1e18;

    /// @notice Minimum number of outcomes a market may have (binary Yes/No).
    uint256 internal constant MIN_OUTCOMES = 2;

    /// @notice Maximum number of outcomes a market may have (generic multi-outcome).
    uint256 internal constant MAX_OUTCOMES = 256;

    /// @notice Maximum outcomes for an LMSR market. Lower than {MAX_OUTCOMES} because every trade
    ///         evaluates one `exp` per outcome; this bounds per-trade gas.
    uint256 internal constant MAX_LMSR_OUTCOMES = 64;

    /// @notice Upper bound on the LMSR liquidity parameter `b`. A safety rail far above any real
    ///         market (1e30 base units == 1e24 USDC) that keeps every 18-dp fixed-point intermediate
    ///         well inside SD59x18 range, so no trade can ever overflow/DoS the market's math.
    uint256 internal constant MAX_LIQUIDITY_PARAM = 1e30;

    /// @notice Upper bound on shares transacted in a single LMSR buy (same safety rationale as above).
    uint256 internal constant MAX_SHARES_PER_TRADE = 1e30;
}

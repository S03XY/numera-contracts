// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "./Constants.sol";

/// @title ParimutuelMath
/// @notice Pure, overflow-safe math for a pooled (parimutuel) prediction market.
/// @dev All ratio math uses OpenZeppelin `Math.mulDiv` for full 512-bit intermediate precision,
///      so `stake * pool` can never overflow even for very large USDC pools.
library ParimutuelMath {
    /// @notice Protocol fee taken from the whole pot at resolution.
    /// @param totalPool Sum of every outcome's staked collateral.
    /// @param feeBps Fee in basis points (already validated <= Constants.MAX_FEE_BPS by the caller).
    /// @return fee The collateral amount owed to the protocol.
    function protocolFee(uint256 totalPool, uint256 feeBps) internal pure returns (uint256 fee) {
        // feeBps <= 10_000 by construction, so mulDiv keeps precision and cannot overflow.
        fee = Math.mulDiv(totalPool, feeBps, Constants.BPS);
    }

    /// @notice Net distributable pot after the protocol fee is removed.
    function netPool(uint256 totalPool, uint256 feeBps) internal pure returns (uint256) {
        return totalPool - protocolFee(totalPool, feeBps);
    }

    /// @notice Payout owed to a winning stake under parimutuel rules.
    /// @dev payout = stake * netPot / winningPool. The winners collectively receive the
    ///      entire `netPot`; each winner's share is proportional to their winning stake.
    ///      Rounding is toward zero (favouring the protocol / dust stays in the contract),
    ///      which guarantees the sum of payouts never exceeds `netPot`.
    /// @param stake The caller's stake on the winning outcome.
    /// @param winningPool Total collateral staked on the winning outcome.
    /// @param netPot Distributable pot (see {netPool}).
    /// @return payout Collateral owed to this stake.
    function winnerPayout(uint256 stake, uint256 winningPool, uint256 netPot)
        internal
        pure
        returns (uint256 payout)
    {
        if (winningPool == 0 || stake == 0) return 0;
        payout = Math.mulDiv(stake, netPot, winningPool);
    }

    /// @notice Implied probability / price of an outcome, in WAD (1e18 == 100%).
    /// @dev price_i = pool_i / totalPool. Returns 0 when the market is empty.
    ///      Prices across all outcomes sum to ~1e18 (minus rounding dust).
    /// @param outcomePool Collateral staked on this outcome.
    /// @param totalPool Sum of every outcome's staked collateral.
    /// @return price Implied probability scaled by 1e18.
    function priceWad(uint256 outcomePool, uint256 totalPool) internal pure returns (uint256 price) {
        if (totalPool == 0) return 0;
        price = Math.mulDiv(outcomePool, Constants.WAD, totalPool);
    }

    /// @notice Effective decimal odds of an outcome, in WAD (e.g. 2.5x == 2.5e18).
    /// @dev odds_i = netPot / pool_i, i.e. what one unit staked on outcome `i` returns
    ///      if it wins, given the current pools. Returns 0 for an empty outcome pool.
    function oddsWad(uint256 outcomePool, uint256 netPot) internal pure returns (uint256) {
        if (outcomePool == 0) return 0;
        return Math.mulDiv(netPot, Constants.WAD, outcomePool);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IResolvableMarket} from "../interfaces/IResolvableMarket.sol";

/// @title MockResolvableMarket
/// @notice Records resolve/invalidate calls and enforces a bound resolver, for isolated tests.
contract MockResolvableMarket is IResolvableMarket {
    address public resolver;

    bool public resolved;
    bool public invalidated;
    uint256 public lastMarketId;
    uint256 public lastWinningOutcome;

    error OnlyResolver();

    constructor(address resolver_) {
        resolver = resolver_;
    }

    function resolve(uint256 marketId, uint256 winningOutcomeId) external {
        if (msg.sender != resolver) revert OnlyResolver();
        resolved = true;
        lastMarketId = marketId;
        lastWinningOutcome = winningOutcomeId;
    }

    function invalidate(uint256 marketId) external {
        if (msg.sender != resolver) revert OnlyResolver();
        invalidated = true;
        lastMarketId = marketId;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IResolvableMarket} from "../interfaces/IResolvableMarket.sol";
import {IMarketEngine} from "../interfaces/IMarketEngine.sol";

/// @title MockOptimisticMarket
/// @notice An engine stand-in with the surface {PrivateOptimisticResolver} actually reads.
/// @dev {MockResolvableMarket} only implements the settlement hooks. The optimistic resolver also
///      reads close time, outcome count and the pot, and it must refuse to settle a market twice —
///      the condition {abandonProposal} exists to recover from.
contract MockOptimisticMarket is IResolvableMarket, IMarketEngine {
    address public resolver;

    bool public resolved;
    bool public invalidated;
    uint256 public lastMarketId;
    uint256 public lastWinningOutcome;

    uint64 private _closeTime;
    uint32 private _outcomeCount;
    uint256 private _pot;

    error OnlyResolver();
    error AlreadySettled();

    constructor(address resolver_, uint64 closeTime_, uint32 outcomeCount_, uint256 pot_) {
        resolver = resolver_;
        _closeTime = closeTime_;
        _outcomeCount = outcomeCount_;
        _pot = pot_;
    }

    function resolve(uint256 marketId, uint256 winningOutcomeId) external {
        if (msg.sender != resolver) revert OnlyResolver();
        if (resolved || invalidated) revert AlreadySettled();
        resolved = true;
        lastMarketId = marketId;
        lastWinningOutcome = winningOutcomeId;
    }

    function invalidate(uint256 marketId) external {
        if (msg.sender != resolver) revert OnlyResolver();
        if (resolved || invalidated) revert AlreadySettled();
        invalidated = true;
        lastMarketId = marketId;
    }

    function marketCount() external pure returns (uint256) {
        return 1;
    }

    function closeTimeOf(uint256) external view returns (uint64) {
        return _closeTime;
    }

    function outcomeCountOf(uint256) external view returns (uint32) {
        return _outcomeCount;
    }

    function collateralOf(uint256) external view returns (uint256) {
        return _pot;
    }

    function setPot(uint256 pot_) external {
        _pot = pot_;
    }
}

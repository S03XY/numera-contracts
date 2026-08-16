// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IResolvableMarket} from "../interfaces/IResolvableMarket.sol";
import {IMarketEngine} from "../interfaces/IMarketEngine.sol";

/// @title MockOptimisticMarket
/// @notice An engine stand-in with the surface {OptimisticResolver} actually reads.
/// @dev {MockResolvableMarket} only implements the settlement hooks. The optimistic resolver also
///      reads close time, outcome count, the pot and the fees a market earned, and it must refuse to
///      settle a market twice — the condition {OptimisticResolver.abandonProposal} recovers from.
///
///      Every optional read can be made to revert with {setViewsBroken}, because the resolver's
///      contract with an engine is that a missing or reverting view degrades the *reward* and never
///      blocks a *settlement*. That is a claim worth testing rather than asserting.
contract MockOptimisticMarket is IResolvableMarket, IMarketEngine {
    address public resolver;

    bool public resolved;
    bool public invalidated;
    uint256 public lastMarketId;
    uint256 public lastWinningOutcome;

    uint64 private _closeTime;
    uint32 private _outcomeCount;
    uint256 private _pot;
    uint256 private _fees;
    bool private _viewsBroken;

    error OnlyResolver();
    error AlreadySettled();
    error ViewsBroken();

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
        if (_viewsBroken) revert ViewsBroken();
        return _pot;
    }

    function feesOf(uint256) external view returns (uint256) {
        if (_viewsBroken) revert ViewsBroken();
        return _fees;
    }

    function isSettled(uint256) external view returns (bool) {
        if (_viewsBroken) revert ViewsBroken();
        return resolved || invalidated;
    }

    function setPot(uint256 pot_) external {
        _pot = pot_;
    }

    function setFees(uint256 fees_) external {
        _fees = fees_;
    }

    function setCloseTime(uint64 closeTime_) external {
        _closeTime = closeTime_;
    }

    /// @notice Make every optional view revert, standing in for an engine that predates them.
    function setViewsBroken(bool broken) external {
        _viewsBroken = broken;
    }
}

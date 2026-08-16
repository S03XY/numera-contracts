// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// -----------------------------------------------------------------------------
// Errors
// File-level custom errors shared across the protocol (cheaper than string reverts).
// Grouped here so error selectors are consistent and documented in one place.
// -----------------------------------------------------------------------------

// ----- Configuration / creation -----
error ZeroAddress();
error InvalidOutcomeCount(uint256 provided, uint256 min, uint256 max);
error FeeTooHigh(uint256 provided, uint256 max);
error CloseTimeInPast(uint64 closeTime, uint64 nowTs);
error EmptyMetadata();

// ----- Market lifecycle -----
error MarketNotFound(uint256 marketId);
error MarketNotTrading(uint256 marketId);
error MarketClosed(uint256 marketId);
error MarketNotClosed(uint256 marketId);
error MarketAlreadyResolved(uint256 marketId);
error MarketNotResolved(uint256 marketId);
error MarketNotInvalid(uint256 marketId);

// ----- Betting / claiming -----
error InvalidOutcome(uint256 outcomeId, uint256 outcomeCount);
error AmountZero();
error AmountBelowMin(uint256 amount, uint256 minAmount);
error NothingToClaim();
error AlreadyClaimed();
error SlippageExceeded(uint256 got, uint256 wanted);

// ----- Scheduling -----
/// @notice Trading was attempted before the market's published start time.
error MarketNotOpenYet(uint256 marketId, uint64 startTime);
/// @notice A market cannot open after it closes, and cannot open in the past.
error InvalidStartTime(uint64 startTime, uint64 closeTime);

// ----- Metadata -----
/// @notice The published copy does not hash to the commitment being stored beside it.
error MetadataMismatch(bytes32 published, bytes32 committed);

// ----- Access / safety -----
error NotResolver(address caller);
error NotAuthorized(address caller);
error ReentrantCall();

// ----- AMM (CPMM) specific -----
error InsufficientLiquidity();
error InsufficientShares(uint256 have, uint256 need);
error ZeroLiquidity();
error LiquidityTooHigh(uint256 provided, uint256 max);
error AmountTooLarge(uint256 provided, uint256 max);

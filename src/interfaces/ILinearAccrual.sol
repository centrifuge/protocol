// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {CompoundingPeriod} from "src/libraries/Compounding.sol";

interface ILinearAccrual {
    /// Events
    event NewRateId(bytes32 indexed rateId, uint128 indexed ratePerPeriod, CompoundingPeriod period);
    event RateAccumulated(bytes32 indexed rateId, uint128 indexed rate, uint64 periodsPassed);

    /// Errors
    error RateIdExists(bytes32 rateId, uint128 ratePerPeriod, CompoundingPeriod period);
    error RateIdMissing(bytes32 rateId);
    error RateIdOutdated(bytes32 rateId, uint64 lastUpdated);

    /// @notice     Updates the accumulated rate of the corresponding identifier based on the periods which have passed
    /// since the last update
    /// @param      rateId the id of the interest rate group
    function drip(bytes32 rateId) external;

    /// @notice     Registers the rate identifier for the given rate and compound period and returns it.
    ///
    /// @param      ratePerPeriod Rate per compound period
    /// @param      period Compounding schedule
    function registerRateId(uint128 ratePerPeriod, CompoundingPeriod period) external returns (bytes32 rateId);

    /// @notice     Returns the rate identifier for the given rate and compound period.
    ///
    /// @param      ratePerPeriod Rate per compound period
    /// @param      period Compounding schedule
    function getRateId(uint128 ratePerPeriod, CompoundingPeriod period) external pure returns (bytes32 rateId);

    /// @notice     Returns the sum of the current normalized debt and the normalized change.
    ///
    /// @param      rateId Identifier of the rate group
    /// @param      prevNormalizedDebt Normalized debt before decreasing
    /// @param      debtChange The amount by which we modify the debt
    function getModifiedNormalizedDebt(bytes32 rateId, int128 prevNormalizedDebt, int128 debtChange)
        external
        view
        returns (int128 newNormalizedDebt);

    /// @notice     Returns the renormalized debt based on the current rate group after transitioning normalization from
    /// the previous one.
    ///
    /// @param      oldRateId Identifier of the previous rate group
    /// @param      newRateId Identifier of the current rate group
    /// @param      prevNormalizedDebt Normalized debt under previous rate group
    function getRenormalizedDebt(bytes32 oldRateId, bytes32 newRateId, int128 prevNormalizedDebt)
        external
        view
        returns (int128 newNormalizedDebt);

    /// @notice     Returns the current debt without normalization based on actual block.timestamp (now) and the
    /// accumulated rate.
    /// @param      rateId Identifier of the rate group
    /// @param      normalizedDebt Normalized debt from which we derive the unnormalized debt
    function debt(bytes32 rateId, int128 normalizedDebt) external view returns (int128 unnormalizedDebt);
}

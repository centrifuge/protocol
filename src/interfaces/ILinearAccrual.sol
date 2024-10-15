// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {CompoundingPeriod} from "../Compounding.sol";

interface ILinearAccrual {
    /// Events
    event NewRateId(bytes32 rateId, uint128 ratePerPeriod, CompoundingPeriod period);
    event RateAccumulated(bytes32 rateId, uint128 rate, uint256 periodsPassed);

    /// Errors
    error RateIdExists(bytes32 rateId, uint128 ratePerPeriod, CompoundingPeriod period);
    error RateIdMissing(bytes32 rateId);
    error RateIdOutdated(bytes32 rateId, uint64 lastUpdated);
    error GroupMissing(bytes32 rateId);

    /// @notice     Returns the rate identifier for the given rate and compound period.
    ///
    /// @param      ratePerPeriod Rate per compound period
    /// @param      period Compounding schedule
    function getRateId(uint128 ratePerPeriod, CompoundingPeriod period) external pure returns (bytes32 rateId);

    /// @notice     Registers the rate identifier for the given rate and compound period and returns it.
    ///
    /// @param      ratePerPeriod Rate per compound period
    /// @param      period Compounding schedule
    function registerRateId(uint128 ratePerPeriod, CompoundingPeriod period) external returns (bytes32 rateId);

    /// @notice     Returns the sum of the current normalized debt and the normalized increment.
    ///
    /// @param      rateId Identifier of the rate group
    /// @param      prevNormalizedDebt Normalized debt before decreasing
    /// @param      debtIncrease The amount by which we increase the debt
    function increaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 debtIncrease)
        external
        view
        returns (uint128 newNormalizedDebt);

    /// @notice     Returns the difference of the current normalized debt and the normalized decrement.
    ///
    /// @param      rateId Identifier of the rate group
    /// @param      prevNormalizedDebt Normalized debt before decreasing
    /// @param      debtDecrease The amount by which we decrease the debt
    function decreaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 debtDecrease)
        external
        view
        returns (uint128 newNormalizedDebt);

    /// @notice     Returns the renormalized debt based on the current rate group after transitioning normalization from
    /// the previous one.
    ///
    /// @param      oldRateId Identifier of the previous rate group
    /// @param      newRateId Identifier of the current rate group
    /// @param      prevNormalizedDebt Normalized debt under previous rate group
    function renormalizeDebt(bytes32 oldRateId, bytes32 newRateId, uint128 prevNormalizedDebt)
        external
        view
        returns (uint128 newNormalizedDebt);
}

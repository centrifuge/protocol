// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {CompoundingPeriod} from "../Compounding.sol";

interface ILinearAccrual {
    event NewRateId(bytes32 rateId, uint128 rate, CompoundingPeriod period);
    event RateAccumulated(bytes32 rateId, uint128 rate, uint256 periodsPassed);

    /// @notice     Returns the rate identifier for the given rate and compound period.
    ///
    /// @dev        Initializes storage if the rate identifier has not existed yet.
    ///
    /// @param      rate Rate
    /// @param      period Compounding schedule
    function getRateId(uint128 rate, CompoundingPeriod period) external returns (bytes32 rateId);

    /// @notice     Returns the sum of the current normalized debt and the normalized increment.
    ///
    /// @dev        Initializes storage if the rate identifier has not existed yet.
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
    /// @dev        Initializes storage if the rate identifier has not existed yet.
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
    /// @dev        Initializes storage if the rate identifier has not existed yet.
    ///
    /// @param      oldRateId Identifier of the previous rate group
    /// @param      newRateId Identifier of the current rate group
    /// @param      prevNormalizedDebt Normalized debt under previous rate group
    function renormalizeDebt(bytes32 oldRateId, bytes32 newRateId, uint128 prevNormalizedDebt)
        external
        view
        returns (uint128 newNormalizedDebt);
}

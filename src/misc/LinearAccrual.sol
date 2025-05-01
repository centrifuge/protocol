// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILinearAccrual} from "src/misc/interfaces/ILinearAccrual.sol";
import {Compounding, CompoundingPeriod} from "src/misc/libraries/Compounding.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {d18, D18, mulUint128} from "src/misc/types/D18.sol";

contract LinearAccrual is ILinearAccrual {
    using MathLib for uint128;
    using MathLib for uint256;
    using MathLib for int128;

    mapping(bytes32 rateId => Rate rate) public rates;
    mapping(bytes32 rateId => Group group) public groups;

    //----------------------------------------------------------------------------------------------
    // Rate updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILinearAccrual
    function drip(bytes32 rateId) public {
        Rate storage rate = rates[rateId];

        // Short circuit to save gas
        if (rate.lastUpdated == uint64(block.timestamp)) {
            return;
        }

        Group memory group = groups[rateId];

        // Determine number of full compounding periods passed since last update
        uint64 periodsPassed = Compounding.getPeriodsPassed(group.period, rate.lastUpdated);

        if (periodsPassed > 0) {
            rate.accumulatedRate = d18(
                rate.accumulatedRate.mulUint128(
                    uint256(group.ratePerPeriod.inner()).rpow(periodsPassed, 1e18).toUint128(), MathLib.Rounding.Up
                )
            );

            emit RateAccumulated(rateId, rate.accumulatedRate.inner(), periodsPassed);
            rate.lastUpdated = uint64(block.timestamp);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Rate registration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILinearAccrual
    function registerRateId(uint128 ratePerPeriod_, CompoundingPeriod period) public returns (bytes32 rateId) {
        D18 ratePerPeriod = d18(ratePerPeriod_);
        Group memory group = Group(ratePerPeriod, period);

        rateId = keccak256(abi.encode(group));

        require(rates[rateId].lastUpdated == 0, RateIdExists(rateId, ratePerPeriod.inner(), period));

        groups[rateId] = group;
        rates[rateId] = Rate(ratePerPeriod, uint64(block.timestamp));

        emit NewRateId(rateId, ratePerPeriod.inner(), period);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILinearAccrual
    function rateIdExists(bytes32 rateId) public view returns (bool) {
        return rates[rateId].lastUpdated > 0;
    }

    /// @inheritdoc ILinearAccrual
    function getRateId(uint128 rate, CompoundingPeriod period) public pure returns (bytes32) {
        Group memory group = Group(d18(rate), period);

        return keccak256(abi.encode(group));
    }

    /// @inheritdoc ILinearAccrual
    function getModifiedNormalizedDebt(bytes32 rateId, int128 prevNormalizedDebt, int128 debtChange)
        external
        view
        returns (int128 newNormalizedDebt)
    {
        _requireNonZeroUpdatedRateId(rateId);

        if (debtChange >= 0) {
            return prevNormalizedDebt
                + rates[rateId].accumulatedRate.reciprocalMulUint128(uint128(debtChange), MathLib.Rounding.Up).toInt128();
        } else {
            return prevNormalizedDebt
                - rates[rateId].accumulatedRate.reciprocalMulUint128(uint128(-debtChange), MathLib.Rounding.Up).toInt128();
        }
    }

    /// @inheritdoc ILinearAccrual
    function getRenormalizedDebt(bytes32 oldRateId, bytes32 newRateId, int128 prevNormalizedDebt)
        external
        view
        returns (int128 newNormalizedDebt)
    {
        _requireNonZeroUpdatedRateId(newRateId);

        int128 debt_ = debt(oldRateId, prevNormalizedDebt);

        if (debt_ >= 0) {
            return rates[newRateId].accumulatedRate.reciprocalMulUint128(
                debt_.toUint256().toUint128(), MathLib.Rounding.Up
            ).toInt128();
        } else {
            return -(
                rates[newRateId].accumulatedRate.reciprocalMulUint128(
                    (-debt_).toUint256().toUint128(), MathLib.Rounding.Up
                ).toInt128()
            );
        }
    }

    /// @inheritdoc ILinearAccrual
    function debt(bytes32 rateId, int128 normalizedDebt) public view returns (int128) {
        _requireNonZeroUpdatedRateId(rateId);

        // Casting to int128 safe because we don't exceed number of digits of normalizedDebt
        // Casting to uint256 necessary for mulDiv
        if (normalizedDebt >= 0) {
            return normalizedDebt.toUint256().mulDiv(rates[rateId].accumulatedRate.inner(), 1e18).toUint128().toInt128();
        } else {
            return -(-normalizedDebt).toUint256().mulDiv(rates[rateId].accumulatedRate.inner(), 1e18).toUint128().toInt128();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @notice Ensures the given rate id was updated in the current block and is not the zero-rate.
    /// @dev Throws if rate has not been updated in the current block
    /// @dev Throws if rate is zero-rate
    /// @param rateId Identifier of the rate group
    function _requireNonZeroUpdatedRateId(bytes32 rateId) internal view {
        require(rates[rateId].lastUpdated != 0 && rates[rateId].accumulatedRate.inner() != 0, RateIdMissing(rateId));
        require(rates[rateId].lastUpdated == block.timestamp, RateIdOutdated(rateId, rates[rateId].lastUpdated));
    }
}

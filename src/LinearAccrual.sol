// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ILinearAccrual} from "src/interfaces/ILinearAccrual.sol";
import {Compounding, CompoundingPeriod} from "src/libraries/Compounding.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {d18, D18, mulInt} from "src/types/D18.sol";

/// @dev Represents the rate accumulator and the timestamp of the last rate update
struct Rate {
    /// @dev Accumulated rate index over time
    D18 accumulatedRate;
    /// @dev Timestamp of last rate update
    uint64 lastUpdated;
}

/// @dev Each group corresponds to a particular compound period and the accrual rate per period
struct Group {
    /// @dev Rate per compound period
    D18 ratePerPeriod;
    /// @dev Duration of compound period
    CompoundingPeriod period;
}

contract LinearAccrual is ILinearAccrual {
    using MathLib for uint128;
    using MathLib for uint256;
    using MathLib for int128;

    mapping(bytes32 rateId => Rate rate) public rates;
    mapping(bytes32 rateId => Group group) public groups;

    /// @inheritdoc ILinearAccrual
    function drip(bytes32 rateId) public {
        Rate storage rate = rates[rateId];
        require(rate.accumulatedRate.inner() != 0, RateIdMissing(rateId));

        // Short circuit to save gas
        if (rate.lastUpdated == uint64(block.timestamp)) {
            return;
        }

        // Infallible since group storage exists iff rate storage exists
        Group memory group = groups[rateId];
        require(group.ratePerPeriod.inner() != 0, "group-missing");

        // Determine number of full compounding periods passed since last update
        uint64 periodsPassed = Compounding.getPeriodsPassed(group.period, rate.lastUpdated);

        if (periodsPassed > 0) {
            rate.accumulatedRate = d18(
                rate.accumulatedRate.mulInt(
                    uint256(group.ratePerPeriod.inner()).rpow(periodsPassed, d18(1e18).inner()).toUint128()
                )
            );

            emit RateAccumulated(rateId, rate.accumulatedRate, periodsPassed);
            rate.lastUpdated = uint64(block.timestamp);
        }
    }

    /// @inheritdoc ILinearAccrual
    function registerRateId(D18 ratePerPeriod, CompoundingPeriod period) public returns (bytes32 rateId) {
        Group memory group = Group(ratePerPeriod, period);

        rateId = keccak256(abi.encode(group));

        require(groups[rateId].ratePerPeriod.inner() == 0, RateIdExists(rateId, ratePerPeriod, period));

        groups[rateId] = group;
        rates[rateId] = Rate(ratePerPeriod, uint64(block.timestamp));

        emit NewRateId(rateId, ratePerPeriod, period);
    }

    /// @inheritdoc ILinearAccrual
    function getRateId(D18 rate, CompoundingPeriod period) public pure returns (bytes32) {
        Group memory group = Group(rate, period);

        return keccak256(abi.encode(group));
    }

    /// @inheritdoc ILinearAccrual
    function getModifiedNormalizedDebt(bytes32 rateId, int128 prevNormalizedDebt, int128 debtChange)
        external
        view
        returns (int128 newNormalizedDebt)
    {
        _requireUpdatedRateId(rateId);

        if (debtChange >= 0) {
            return prevNormalizedDebt + rates[rateId].accumulatedRate.reciprocalMulInt(uint128(debtChange)).toInt128();
        } else {
            return prevNormalizedDebt - rates[rateId].accumulatedRate.reciprocalMulInt(uint128(-debtChange)).toInt128();
        }
    }

    /// @inheritdoc ILinearAccrual
    function getRenormalizedDebt(bytes32 oldRateId, bytes32 newRateId, int128 prevNormalizedDebt)
        external
        view
        returns (int128 newNormalizedDebt)
    {
        _requireUpdatedRateId(newRateId);

        int128 debt_ = debt(oldRateId, prevNormalizedDebt);

        if (debt_ >= 0) {
            return rates[newRateId].accumulatedRate.reciprocalMulInt(debt_.toUint256().toUint128()).toInt128();
        } else {
            return -(rates[newRateId].accumulatedRate.reciprocalMulInt((-debt_).toUint256().toUint128()).toInt128());
        }
    }

    /// @inheritdoc ILinearAccrual
    function debt(bytes32 rateId, int128 normalizedDebt) public view returns (int128) {
        _requireUpdatedRateId(rateId);

        // @dev Casting to int128 safe because we don't exceed number of digits of normalizedDebt
        // @dev Casting to uint256 necessary for mulDiv
        if (normalizedDebt >= 0) {
            return normalizedDebt.toUint256().mulDiv(rates[rateId].accumulatedRate.inner(), 1e18).toUint128().toInt128();
        } else {
            return -(-normalizedDebt).toUint256().mulDiv(rates[rateId].accumulatedRate.inner(), 1e18).toUint128().toInt128();
        }
    }

    function _requireUpdatedRateId(bytes32 rateId) internal view {
        require(rates[rateId].lastUpdated != 0, RateIdMissing(rateId));
        require(rates[rateId].lastUpdated == block.timestamp, RateIdOutdated(rateId, rates[rateId].lastUpdated));
    }
}

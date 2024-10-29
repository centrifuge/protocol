// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ILinearAccrual} from "src/interfaces/ILinearAccrual.sol";
import {Compounding, CompoundingPeriod} from "src/Compounding.sol";
import {MathLib} from "src/libraries/MathLib.sol";

/// @dev Represents the rate accumulator and the timestamp of the last rate update
struct Rate {
    /// @dev Accumulated rate index over time
    uint128 accumulatedRate;
    /// @dev Timestamp of last rate update
    uint64 lastUpdated;
}

/// @dev Each group corresponds to a particular compound period and the accrual rate per period
struct Group {
    /// @dev Rate per compound period
    uint128 ratePerPeriod;
    /// @dev Duration of compound period
    CompoundingPeriod period;
}

contract LinearAccrual is ILinearAccrual {
    using MathLib for uint128;
    using MathLib for uint256;

    mapping(bytes32 rateId => Rate rate) public rates;
    mapping(bytes32 rateId => Group group) public groups;

    /// @inheritdoc ILinearAccrual
    function drip(bytes32 rateId) public {
        Rate storage rate = rates[rateId];
        require(rate.accumulatedRate != 0, RateIdMissing(rateId));

        // Short circuit to save gas
        if (rate.lastUpdated == uint64(block.timestamp)) {
            return;
        }

        // Infallible since group storage exists iff rate storage exists
        Group memory group = groups[rateId];
        require(group.ratePerPeriod != 0, "group-missing");

        // Determine number of full compounding periods passed since last update
        uint64 periodsPassed = Compounding.getPeriodsPassed(group.period, rate.lastUpdated);

        if (periodsPassed > 0) {
            rate.accumulatedRate = group.ratePerPeriod.rpow(periodsPassed, MathLib.One18).mulDiv(
                rate.accumulatedRate, MathLib.One18
            ).toUint128();

            emit RateAccumulated(rateId, rate.accumulatedRate, periodsPassed);
            rate.lastUpdated = uint64(block.timestamp);
        }
    }

    /// @inheritdoc ILinearAccrual
    function registerRateId(uint128 ratePerPeriod, CompoundingPeriod period) public returns (bytes32 rateId) {
        Group memory group = Group(ratePerPeriod, period);

        rateId = keccak256(abi.encode(group));
        if (groups[rateId].ratePerPeriod == 0) {
            groups[rateId] = group;
            // TODO(@wischli): Some source stated another timestamp should be used instead of block.timestamp
            rates[rateId] = Rate(ratePerPeriod, uint64(block.timestamp));
            emit NewRateId(rateId, ratePerPeriod, period);
        } else {
            revert RateIdExists(rateId, ratePerPeriod, period);
        }
    }

    /// @inheritdoc ILinearAccrual
    function getRateId(uint128 rate, CompoundingPeriod period) public pure returns (bytes32) {
        Group memory group = Group(rate, period);

        return keccak256(abi.encode(group));
    }

    /// @inheritdoc ILinearAccrual
    function getIncreasedNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 debtIncrease)
        external
        view
        returns (uint128 newNormalizedDebt)
    {
        _requireUpdatedRateId(rateId);

        // TODO(@review): Discuss if precions better if we do (prev * rate + debtIncrease) / rate
        return prevNormalizedDebt + debtIncrease / rates[rateId].accumulatedRate;
    }

    /// @inheritdoc ILinearAccrual
    function getDecreasedNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 debtDecrease)
        external
        view
        returns (uint128 newNormalizedDebt)
    {
        _requireUpdatedRateId(rateId);

        return prevNormalizedDebt - debtDecrease / rates[rateId].accumulatedRate;
    }

    /// @inheritdoc ILinearAccrual
    function getRenormalizedDebt(bytes32 oldRateId, bytes32 newRateId, uint128 prevNormalizedDebt)
        external
        view
        returns (uint128 newNormalizedDebt)
    {
        _requireUpdatedRateId(oldRateId);
        _requireUpdatedRateId(newRateId);

        uint256 debt_ = debt(oldRateId, prevNormalizedDebt);
        return (debt_ / rates[newRateId].accumulatedRate).toUint128();
    }

    /// @inheritdoc ILinearAccrual
    function debt(bytes32 rateId, uint128 normalizedDebt) public view returns (uint256) {
        _requireUpdatedRateId(rateId);

        return normalizedDebt.mulDiv(rates[rateId].accumulatedRate, MathLib.One18);
    }

    function _requireUpdatedRateId(bytes32 rateId) internal view {
        require(rates[rateId].lastUpdated != 0, RateIdMissing(rateId));
        require(rates[rateId].lastUpdated == block.timestamp, RateIdOutdated(rateId, rates[rateId].lastUpdated));
    }
}

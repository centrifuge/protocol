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
    mapping(bytes32 rateId => Rate rate) public rates;
    mapping(bytes32 rateId => Group group) public groups;

    modifier onlyUpdatedRate(bytes32 rateId) {
        require(rates[rateId].lastUpdated != 0, RateIdMissing(rateId));
        require(rates[rateId].lastUpdated == block.timestamp, RateIdOutdated(rateId, rates[rateId].lastUpdated));
        _;
    }

    /// @inheritdoc ILinearAccrual
    function getRateId(uint128 rate, CompoundingPeriod period) public pure returns (bytes32) {
        Group memory group = Group(rate, period);

        return keccak256(abi.encode(group));
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
    function increaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 debtIncrease)
        external
        view
        onlyUpdatedRate(rateId)
        returns (uint128 newNormalizedDebt)
    {
        // TODO(@review): Discuss if precions better if we do (prev * rate + debtIncrease) / rate
        return prevNormalizedDebt + debtIncrease / rates[rateId].accumulatedRate;
    }

    /// @inheritdoc ILinearAccrual
    function decreaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 debtDecrease)
        external
        view
        onlyUpdatedRate(rateId)
        returns (uint128 newNormalizedDebt)
    {
        return prevNormalizedDebt - debtDecrease / rates[rateId].accumulatedRate;
    }

    /// @inheritdoc ILinearAccrual
    function renormalizeDebt(bytes32 oldRateId, bytes32 newRateId, uint128 prevNormalizedDebt)
        external
        view
        onlyUpdatedRate(oldRateId)
        onlyUpdatedRate(newRateId)
        returns (uint128 newNormalizedDebt)
    {
        uint256 _debt = debt(oldRateId, prevNormalizedDebt);
        return MathLib.toUint128(_debt / rates[newRateId].accumulatedRate);
    }

    /// @inheritdoc ILinearAccrual
    function debt(bytes32 rateId, uint128 normalizedDebt) public view onlyUpdatedRate(rateId) returns (uint256) {
        return MathLib.mulDiv(normalizedDebt, rates[rateId].accumulatedRate, MathLib.One18);
    }

    /// @notice     Updates the accumulated rate of the corresponding identifier based on the periods which have passed
    /// since the last update
    /// @param      rateId the id of the interest rate group
    function drip(bytes32 rateId) public {
        Rate storage rate = rates[rateId];
        require(rate.accumulatedRate != 0, RateIdMissing(rateId));

        // Short circuit to save gas
        if (rate.lastUpdated == uint64(block.timestamp)) {
            return;
        }

        // Infallible since group storage exists iff rate storage exists
        Group memory group = groups[rateId];
        require(group.ratePerPeriod != 0, GroupMissing(rateId));

        // Determine number of full compounding periods passed since last update
        uint256 periodsPassed = Compounding.getPeriodsPassed(group.period, rate.lastUpdated);

        if (periodsPassed > 0) {
            rate.accumulatedRate = MathLib.toUint128(
                MathLib.mulDiv(
                    MathLib.rpow(group.ratePerPeriod, periodsPassed, MathLib.One18), rate.accumulatedRate, MathLib.One18
                )
            );

            emit RateAccumulated(rateId, rate.accumulatedRate, periodsPassed);
            rate.lastUpdated = uint64(block.timestamp);
        }
    }
}

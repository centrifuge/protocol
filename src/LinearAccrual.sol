// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ILinearAccrual} from "./ILinearAccrual.sol";
import {Compounding, CompoundingPeriod} from "./Compounding.sol";

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
        require(
            rates[rateId].accumulatedRate != 0,
            "rate-group-not-initialized"
        );
        require(
            rates[rateId].lastUpdated == block.timestamp,
            "rate-group-not-updated"
        );
        _;
    }

    /// @inheritdoc ILinearAccrual
    function getRateId(
        uint128 rate,
        CompoundingPeriod period
    ) public returns (bytes32 rateId) {
        Group memory group = Group(rate, period);

        // TODO: Discuss how to be future-proof if Group is altered
        rateId = keccak256(abi.encode(group));
        if (groups[rateId].ratePerPeriod == 0) {
            groups[rateId] = group;
            rates[rateId] = Rate(rate, uint64(block.timestamp));
            emit NewRateId(rate, period, rateId);
        }
    }

    /// @inheritdoc ILinearAccrual
    function increaseNormalizedDebt(
        bytes32 rateId,
        uint128 prevNormalizedDebt,
        uint128 debtIncrease
    )
        external
        view
        onlyUpdatedRate(rateId)
        returns (uint128 newNormalizedDebt)
    {
        return
            prevNormalizedDebt + debtIncrease / rates[rateId].accumulatedRate;
    }

    /// @inheritdoc ILinearAccrual
    function decreaseNormalizedDebt(
        bytes32 rateId,
        uint128 prevNormalizedDebt,
        uint128 debtDecrease
    )
        external
        view
        onlyUpdatedRate(rateId)
        returns (uint128 newNormalizedDebt)
    {
        return
            prevNormalizedDebt - debtDecrease / rates[rateId].accumulatedRate;
    }

    /// @inheritdoc ILinearAccrual
    function renormalizeDebt(
        bytes32 oldRateId,
        bytes32 newRateId,
        uint128 prevNormalizedDebt
    )
        external
        view
        onlyUpdatedRate(oldRateId)
        onlyUpdatedRate(newRateId)
        returns (uint128 newNormalizedDebt)
    {
        uint256 _debt = debt(oldRateId, prevNormalizedDebt);
        // TODO: Ensure casting uint256 -> uint128 is feasible
        return uint128(_debt / rates[newRateId].accumulatedRate);
    }

    /// @notice     Returns the current debt without normalization based on actual block.timestamp (now) and the accumulated rate.
    /// @param      rateId Identifier of the rate group
    /// @param      normalizedDebt Normalized debt from which we derive the debt
    function debt(
        bytes32 rateId,
        uint128 normalizedDebt
    ) public view onlyUpdatedRate(rateId) returns (uint256) {
        return normalizedDebt * rates[rateId].accumulatedRate;
    }

    /// @notice Updates the accumulated rate of the corresponding identifier based on the current timestamp
    /// @param rateId the id of the interest rate group
    function drip(bytes32 rateId) public {
        Rate storage rate = rates[rateId];
        require(rate.accumulatedRate != 0, "rate-group-not-initialized");
        Group memory group = groups[rateId];
        // TODO: Improve error names
        require(group.ratePerPeriod != 0, "group-not-initialized");

        // Determine numbert of full compounding periods passed since last update
        uint256 compoundingIntervals = Compounding.getPeriodsPassed(
            group.period,
            rate.lastUpdated
        );

        // TODO: Apply rpow
    }
}

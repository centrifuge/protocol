// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

enum CompoundingPeriod {
    Secondly,
    Daily
}

library Compounding {
    uint64 constant SECONDS_PER_DAY = 86400; // 60 * 60 * 24

    /// @notice Returns the amount of seconds for the given compounding period.
    ///
    /// @dev    Default case is `CompoundingPeriod.Daily`.
    function getSeconds(CompoundingPeriod period) public pure returns (uint64) {
        if (period == CompoundingPeriod.Daily) return SECONDS_PER_DAY;
        else return 1;
    }

    /// @notice Returns the number of full compounding periods that have passed since a given timestamp.
    ///
    /// @dev    Default case is `CompoundingPeriod.Daily` and returns 0 for any given future timestamp.
    function getPeriodsPassed(CompoundingPeriod period, uint64 startTimestamp) public view returns (uint64) {
        if (startTimestamp >= block.timestamp) {
            return 0;
        } else if (period == CompoundingPeriod.Daily) {
            uint64 startDay = startTimestamp / SECONDS_PER_DAY;
            uint64 nowDay = uint64(block.timestamp) / SECONDS_PER_DAY;
            return nowDay - startDay;
        } else {
            return uint64(block.timestamp) - startTimestamp;
        }
    }
}

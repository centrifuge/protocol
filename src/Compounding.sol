// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

enum CompoundingPeriod {
    Secondly,
    Daily
}

library Compounding {
    uint256 constant SECONDS_PER_DAY = 86400; // 60 * 60 * 24

    /// @notice Returns the amount of seconds for the given compounding period.
    ///
    /// @dev    Default case is `CompoundingPeriod.Secondly`.
    function getSeconds(CompoundingPeriod period) public pure returns (uint256) {
        if (period == CompoundingPeriod.Daily) return SECONDS_PER_DAY;
        else return 1;
    }

    /// @notice Returns the number of full compounding periods that have passed since a given timestamp.
    ///
    /// @dev    Default case is `CompoundingPeriod.Secondly` and returns 0 for any given future timestamp.
    function getPeriodsPassed(CompoundingPeriod period, uint256 startTimestamp) public view returns (uint256) {
        if (startTimestamp >= block.timestamp) {
            return 0;
        } else if (period == CompoundingPeriod.Daily) {
            uint256 startDay = startTimestamp / SECONDS_PER_DAY;
            uint256 nowDay = block.timestamp / SECONDS_PER_DAY;
            return nowDay - startDay;
        } else {
            return block.timestamp - startTimestamp;
        }
    }
}

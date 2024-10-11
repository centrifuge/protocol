// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

enum CompoundingPeriod {
    Secondly,
    Daily,
    Quarterly,
    Biannually,
    Annually
}

library Compounding {
    uint256 constant SECONDS_PER_DAY = 86400; // 60 * 60 * 24
    uint256 constant SECONDS_PER_YEAR = 31104000; // 360 days for a commercial year (360 * 86400)
    uint256 constant SECONDS_PER_MONTH = SECONDS_PER_YEAR / 12;

    /// @notice Returns the amount of seconds for the given compounding period.
    ///
    /// @dev    In finance, one year is composed of 12 months of 30 days such that 360 days
    ///         represent a commercial year.
    function getSeconds(
        CompoundingPeriod period
    ) public pure returns (uint256) {
        if (period == CompoundingPeriod.Secondly) return 1;
        if (period == CompoundingPeriod.Daily) return SECONDS_PER_DAY;
        if (period == CompoundingPeriod.Quarterly) return SECONDS_PER_YEAR / 4; // 3 months
        if (period == CompoundingPeriod.Biannually) return SECONDS_PER_YEAR / 2; // 6 months
        if (period == CompoundingPeriod.Annually) return SECONDS_PER_YEAR; // 12 months
        revert("invalid-compounding-period");
    }

    /// @notice Returns the number of full compounding periods that have passed since a given timestamp.
    ///
    /// @dev    In finance, one year is composed of 12 months of 30 days such that 360 days
    ///         represent a commercial year. Uses 0am UTC as the cutoff time for daily, quarterly, biannually, and annually.
    function getPeriodsPassed(
        CompoundingPeriod period,
        uint256 startTimestamp
    ) public view returns (uint256) {
        // TODO: Discuss revert vs. return
        if (startTimestamp >= block.timestamp) return 0;

        if (period == CompoundingPeriod.Secondly) {
            return block.timestamp - startTimestamp;
        } else if (period == CompoundingPeriod.Daily) {
            uint256 startDay = startTimestamp / SECONDS_PER_DAY;
            uint256 nowDay = block.timestamp / SECONDS_PER_DAY;
            return nowDay - startDay;
        } else if (
            period == CompoundingPeriod.Quarterly ||
            period == CompoundingPeriod.Biannually ||
            period == CompoundingPeriod.Annually
        ) {
            (uint256 startYear, uint256 startMonth) = getYearAndMonth(
                startTimestamp
            );
            (uint256 nowYear, uint256 nowMonth) = getYearAndMonth(
                block.timestamp
            );

            if (period == CompoundingPeriod.Quarterly) {
                uint256 startQuarter = startMonth / 3;
                uint256 nowQuarter = nowMonth / 3;
                return 4 * (nowYear - startYear) - startQuarter + nowQuarter;
            } else if (period == CompoundingPeriod.Biannually) {
                uint256 startHalf = startMonth / 6;
                uint256 nowHalf = nowMonth / 6;
                return (nowYear - startYear) * 2 + (nowHalf - startHalf);
            } else if (period == CompoundingPeriod.Annually) {
                return nowYear - startYear;
            }
        }
        revert("invalid-compounding-period");
    }

    /// @dev Get the year and month from a timestamp (approximate)
    ///      Based on a commercial year of 360 days, with 12 months of 30 days each.
    function getYearAndMonth(
        uint256 timestamp
    ) internal pure returns (uint256 year, uint256 month) {
        year = (timestamp / SECONDS_PER_YEAR);
        uint256 daysIntoYear = (timestamp % SECONDS_PER_YEAR) / SECONDS_PER_DAY;
        month = daysIntoYear / 30;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Compounding, CompoundingPeriod} from "src/libraries/Compounding.sol";

contract TestCompounding is Test {
    function testGetSeconds() public pure {
        _testGetSeconds(CompoundingPeriod.Secondly, 1);
        _testGetSeconds(CompoundingPeriod.Daily, 86400);
    }

    function testGetPeriodsSimpleSecondly() public {
        CompoundingPeriod period = CompoundingPeriod.Secondly;

        _testGetPeriodsZero(period);
        _testGetPeriodsOne(period);
        _testGetPeriodsFuture(period);
        _testGetPeriodsBeforePeriodIncrement(period);
    }

    function testGetPeriodsSimpleDaily() public {
        CompoundingPeriod period = CompoundingPeriod.Daily;

        _testGetPeriodsZero(period);
        _testGetPeriodsOne(period);
        _testGetPeriodsFuture(period);
        _testGetPeriodsBeforePeriodIncrement(period);
    }

    function testGetPeriodsIntervals(uint8 periodInt, uint64 start, uint64 end) public {
        vm.assume(start < end);
        CompoundingPeriod period =
            CompoundingPeriod(bound(periodInt, uint8(CompoundingPeriod.Secondly), uint8(CompoundingPeriod.Daily)));
        start = uint64(bound(start, 2, type(uint64).max / Compounding.getSeconds(CompoundingPeriod.Daily)));
        end = uint64(bound(end, start + 1, type(uint64).max / Compounding.getSeconds(CompoundingPeriod.Daily)));
        _testGetPeriodsPassed(period, start, end);
    }

    function testGetPeriodsUTC() public {
        // 2024-1-1 00:00:00 UTC
        uint64 genesis = 1704067200;
        vm.warp(genesis);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Secondly, genesis), 0);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Daily, genesis), 0);

        // 2024-1-2 00:00:00 UTC
        uint64 oneDayAfterGenesis = 1704153600;
        assertEq(genesis + Compounding.SECONDS_PER_DAY, oneDayAfterGenesis);
        vm.warp(oneDayAfterGenesis);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Secondly, genesis), Compounding.SECONDS_PER_DAY);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Daily, genesis), 1);

        // 2024-1-2 23:59:59 UTC
        vm.warp(oneDayAfterGenesis + Compounding.SECONDS_PER_DAY - 1);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Secondly, genesis), 2 * Compounding.SECONDS_PER_DAY - 1);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Daily, genesis), 1);

        // 2024-1-3 00:00:00 UTC
        vm.warp(oneDayAfterGenesis + Compounding.SECONDS_PER_DAY);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Secondly, genesis), 2 * Compounding.SECONDS_PER_DAY);
        assertEq(Compounding.getPeriodsPassed(CompoundingPeriod.Daily, genesis), 2);
    }

    function _testGetPeriodsZero(CompoundingPeriod period) internal view {
        require(
            Compounding.getPeriodsPassed(period, uint64(block.timestamp)) == 0,
            string(
                abi.encodePacked(
                    "getPeriodsPassed should return 0 for ",
                    _periodToString(period),
                    " compounding at current timestamp"
                )
            )
        );
    }

    function _testGetPeriodsOne(CompoundingPeriod period) internal {
        uint64 periodLength = Compounding.getSeconds(period);

        vm.warp(periodLength);
        require(
            Compounding.getPeriodsPassed(period, periodLength - 1) == 1,
            string(
                abi.encodePacked(
                    "getPeriodsPassed should return 1 for ",
                    _periodToString(period),
                    " compounding at one second before new period"
                )
            )
        );
    }

    function _testGetPeriodsFuture(CompoundingPeriod period) internal {
        vm.warp(0);
        require(
            Compounding.getPeriodsPassed(period, 1) == 0,
            string(
                abi.encodePacked(
                    "getPeriodsPassed should return 0 for ",
                    _periodToString(period),
                    " compounding if start is in future"
                )
            )
        );
    }

    function _testGetPeriodsBeforePeriodIncrement(CompoundingPeriod period) internal {
        uint64 periodLength = Compounding.getSeconds(period);

        vm.warp(periodLength - 1);
        require(
            Compounding.getPeriodsPassed(period, 0) == 0,
            string(
                abi.encodePacked(
                    "getPeriodsPassed should return 0 for ",
                    _periodToString(period),
                    " compounding if less than a period has passed"
                )
            )
        );
    }

    function _testGetSeconds(CompoundingPeriod period, uint64 expectedSeconds) internal pure {
        uint64 compoundingSeconds = Compounding.getSeconds(period);
        require(
            compoundingSeconds == expectedSeconds,
            string(
                abi.encodePacked(
                    "getSeconds should return ", expectedSeconds, " for ", _periodToString(period), " compounding"
                )
            )
        );
    }

    function _testGetPeriodsPassed(CompoundingPeriod period, uint64 start, uint64 end) internal {
        require(end > start, "end must be greater than start");
        uint64 periodLength = Compounding.getSeconds(period);

        vm.warp(end * periodLength - 1 seconds);
        uint64 expectedPeriods = end - start - 1;
        require(
            Compounding.getPeriodsPassed(period, start * periodLength) == expectedPeriods,
            string(
                abi.encodePacked(
                    "getPeriodsPassed should return ",
                    expectedPeriods,
                    " for ",
                    _periodToString(period),
                    " compounding for interval"
                )
            )
        );
    }

    function _periodToString(CompoundingPeriod period) internal pure returns (string memory) {
        if (period == CompoundingPeriod.Secondly) return "Secondly";
        else if (period == CompoundingPeriod.Daily) return "Daily";
        else return "Unknown";
    }
}

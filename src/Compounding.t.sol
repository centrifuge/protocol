// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import "./Compounding.sol";

// TODO: Add fuzz testing
contract TestCompounding is Test {
    function testGetSeconds() public pure {
        _testGetSeconds(CompoundingPeriod.Secondly, 1);
        _testGetSeconds(CompoundingPeriod.Daily, 86400);
        _testGetSeconds(CompoundingPeriod.Quarterly, 7776000);
        _testGetSeconds(CompoundingPeriod.Biannually, 15552000);
        _testGetSeconds(CompoundingPeriod.Annually, 31104000);
    }

    function testGetPeriodsPassedSecondly() public {
        _testGetPeriodsPassed(CompoundingPeriod.Secondly, 47, 100);
    }

    function testGetPeriodsPassedDaily() public {
        _testGetPeriodsPassed(CompoundingPeriod.Daily, 3, 10);
    }

    function testGetPeriodsPassedQuarterly() public {
        _testGetPeriodsPassed(CompoundingPeriod.Quarterly, 2, 123);
    }

    function testGetPeriodsPassedBiannually() public {
        _testGetPeriodsPassed(CompoundingPeriod.Biannually, 2, 1000);
    }

    function testGetPeriodsPassedAnnually() public {
        _testGetPeriodsPassed(CompoundingPeriod.Annually, 2, 12312);
    }

    function _testGetSeconds(CompoundingPeriod period, uint256 expectedSeconds) internal pure {
        uint256 compoundingSeconds = Compounding.getSeconds(period);
        require(
            compoundingSeconds == expectedSeconds,
            string(
                abi.encodePacked(
                    "getSeconds should return ", expectedSeconds, " for ", _periodToString(period), " compounding"
                )
            )
        );
    }

    function _testGetPeriodsPassed(
        CompoundingPeriod period,
        uint256 intervalMultiplierStart,
        uint256 intervalMultiplierEnd
    ) internal {
        require(intervalMultiplierStart > 1, "multiplier > 1 required");
        require(intervalMultiplierEnd > intervalMultiplierStart, "end must be greater than start");
        uint256 periodLength = Compounding.getSeconds(period);

        // Test case: start in future
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

        // Test case: current timestamp
        require(
            Compounding.getPeriodsPassed(period, block.timestamp) == 0,
            string(
                abi.encodePacked(
                    "getPeriodsPassed should return 0 for ",
                    _periodToString(period),
                    " compounding at current timestamp"
                )
            )
        );

        // Test case: now minus one second
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

        // Test case: warp to exact periodLength and check
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

        // Test case: within interval between period and end of 10th interval
        vm.warp(intervalMultiplierEnd * periodLength - 1 seconds);
        uint256 expectedPeriods = intervalMultiplierEnd - intervalMultiplierStart - 1;
        require(
            Compounding.getPeriodsPassed(period, intervalMultiplierStart * periodLength) == expectedPeriods,
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
        if (period == CompoundingPeriod.Daily) return "Daily";
        if (period == CompoundingPeriod.Quarterly) return "Quarterly";
        if (period == CompoundingPeriod.Biannually) return "Biannually";
        if (period == CompoundingPeriod.Annually) return "Annually";
        return "Unknown";
    }
}

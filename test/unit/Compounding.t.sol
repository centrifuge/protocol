// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import "src/Compounding.sol";

contract TestCompounding is Test {
    /// @dev    Using `uint8` over real type `CompoundingPeriod` since fuzzer exceeds bounds if using real type, even if
    ///         limited assumption.
    uint8[5] public fixturePeriod = [
        uint8(CompoundingPeriod.Secondly),
        uint8(CompoundingPeriod.Daily),
        uint8(CompoundingPeriod.Quarterly),
        uint8(CompoundingPeriod.Biannually),
        uint8(CompoundingPeriod.Annually)
    ];

    function testGetSeconds() public pure {
        _testGetSeconds(CompoundingPeriod.Secondly, 1);
        _testGetSeconds(CompoundingPeriod.Daily, 86400);
        _testGetSeconds(CompoundingPeriod.Quarterly, 7776000);
        _testGetSeconds(CompoundingPeriod.Biannually, 15552000);
        _testGetSeconds(CompoundingPeriod.Annually, 31104000);
    }

    function testGetPeriodsSimple() public {
        for (uint8 i = 0; i < fixturePeriod.length; i++) {
            _testGetPeriodsZero(CompoundingPeriod(i));
            _testGetPeriodsOne(CompoundingPeriod(i));
            _testGetPeriodsFuture(CompoundingPeriod(i));
            _testGetPeriodsBeforePeriodIncrement(CompoundingPeriod(i));
        }
    }

    function testGetPeriodsIntervals(uint8 period, uint256 start, uint256 end) public {
        vm.assume(period < uint8(CompoundingPeriod.Annually));
        vm.assume(start < end);
        start = uint256(bound(start, 2, type(uint128).max / Compounding.getSeconds(CompoundingPeriod.Annually)));
        end = uint256(bound(end, start + 1, type(uint128).max / Compounding.getSeconds(CompoundingPeriod.Annually)));
        _testGetPeriodsPassed(CompoundingPeriod(period), start, end);
    }

    function _testGetPeriodsZero(CompoundingPeriod period) internal view {
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
    }

    function _testGetPeriodsOne(CompoundingPeriod period) internal {
        uint256 periodLength = Compounding.getSeconds(period);

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
        uint256 periodLength = Compounding.getSeconds(period);

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

    function _testGetPeriodsPassed(CompoundingPeriod period, uint256 start, uint256 end) internal {
        require(end > start, "end must be greater than start");
        uint256 periodLength = Compounding.getSeconds(period);

        vm.warp(end * periodLength - 1 seconds);
        uint256 expectedPeriods = end - start - 1;
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
        if (period == CompoundingPeriod.Daily) return "Daily";
        if (period == CompoundingPeriod.Quarterly) return "Quarterly";
        if (period == CompoundingPeriod.Biannually) return "Biannually";
        if (period == CompoundingPeriod.Annually) return "Annually";
        return "Unknown";
    }
}

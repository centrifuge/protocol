// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./LinearAccrual.sol";
import "./interfaces/ILinearAccrual.sol";
import "./Compounding.sol";

contract TestLinearAccrual is Test {
    LinearAccrual linearAccrual;

    event NewRateId(uint128 rate, CompoundingPeriod period, bytes32 rateId);

    function setUp() public {
        linearAccrual = new LinearAccrual();
        vm.warp(1 days);
    }

    function testGetRateId() public {
        uint128 rate = 5 * 10 ** 18;
        CompoundingPeriod period = CompoundingPeriod.Quarterly;
        vm.expectEmit(true, true, true, true);
        emit NewRateId(rate, period, keccak256(abi.encode(Group(rate, period))));
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        (uint128 ratePerPeriod, CompoundingPeriod retrievedPeriod) = linearAccrual.groups(rateId);
        assertEq(ratePerPeriod, rate, "Rate per period mismatch");
        assertEq(uint256(retrievedPeriod), uint256(period), "Period mismatch");

        (uint128 accumulatedRate, uint64 lastUpdated) = linearAccrual.rates(rateId);
        assertEq(accumulatedRate, rate, "Initial accumulated rate mismatch");
        assertEq(uint256(lastUpdated), block.timestamp, "Last updated mismatch");
    }

    function testIncreaseNormalizedDebt() public {
        uint128 rate = 5 * 10 ** 18;
        CompoundingPeriod period = CompoundingPeriod.Quarterly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        uint128 prevNormalizedDebt = 100 * 10 ** 18;
        uint128 debtIncrease = 50 * 10 ** 18;

        // Update rate to current timestamp for modifier check
        linearAccrual.drip(rateId);

        (uint128 accumulatedRate,) = linearAccrual.rates(rateId);
        uint128 newDebt = linearAccrual.increaseNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
        uint128 expectedDebt = prevNormalizedDebt + (debtIncrease / accumulatedRate);

        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testDecreaseNormalizedDebt() public {
        uint128 rate = 5 * 10 ** 18;
        CompoundingPeriod period = CompoundingPeriod.Quarterly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        uint128 prevNormalizedDebt = 100 * 10 ** 18;
        uint128 debtDecrease = 20 * 10 ** 18;

        // Update rate to current timestamp for modifier check
        linearAccrual.drip(rateId);

        (uint128 accumulatedRate,) = linearAccrual.rates(rateId);
        uint128 newDebt = linearAccrual.decreaseNormalizedDebt(rateId, prevNormalizedDebt, debtDecrease);
        uint128 expectedDebt = prevNormalizedDebt - (debtDecrease / accumulatedRate);

        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    // FIXME: @wischli overflow/underflow
    // function testRenormalizeDebt() public {
    //     uint128 oldRate = 5 * 10 ** 18;
    //     uint128 newRate = 10 * 10 ** 18;
    //     CompoundingPeriod period = CompoundingPeriod.Quarterly;
    //     bytes32 oldRateId = linearAccrual.getRateId(oldRate, period);
    //     bytes32 newRateId = linearAccrual.getRateId(newRate, period);

    //     uint128 prevNormalizedDebt = 100 * 10 ** 18;

    //     // Update rates to current timestamp for modifier check
    //     linearAccrual.drip(oldRateId);
    //     linearAccrual.drip(newRateId);

    //     (uint128 accumulatedRateOld,) = linearAccrual.rates(oldRateId);
    //     (uint128 accumulatedRateNew,) = linearAccrual.rates(newRateId);

    //     uint256 _debt = prevNormalizedDebt * accumulatedRateOld;
    //     uint256 expectedDebt = _debt / accumulatedRateNew;

    //     uint128 newNormalizedDebt = linearAccrual.renormalizeDebt(oldRateId, newRateId, prevNormalizedDebt);

    //     assertEq(newNormalizedDebt, expectedDebt, "Incorrect renormalized debt");
    // }

    // function testDebtCalculation() public {
    //     uint128 rate = 5 * 10 ** 18;
    //     CompoundingPeriod period = CompoundingPeriod.Daily;
    //     bytes32 rateId = linearAccrual.getRateId(rate, period);

    //     uint128 normalizedDebt = 100 * 10 ** 18;

    //     // Update rate to current timestamp for modifier check
    //     linearAccrual.drip(rateId);

    //     (uint128 accumulatedRate,) = linearAccrual.rates(rateId);
    //     uint256 currentDebt = linearAccrual.debt(rateId, normalizedDebt);
    //     uint256 expectedDebt = normalizedDebt * accumulatedRate;

    //     assertEq(currentDebt, expectedDebt, "Incorrect debt calculation");
    // }

    function testDripUpdatesRate() public {
        // 1.23 with 27 decimal precision
        uint128 rate = 123 * 10 ** 25;
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Pass one period
        (, uint64 initialLastUpdated) = linearAccrual.rates(rateId);
        vm.warp(initialLastUpdated + 1 seconds);

        linearAccrual.drip(rateId);

        (uint128 updatedRate,) = linearAccrual.rates(rateId);
        uint256 rateSquare = uint256(rate) * uint256(rate) / (10 ** 27);
        assertEq(uint256(updatedRate), rateSquare, "Rate should be quadratic after one period");

        // Pass 3 more periods
        vm.warp(block.timestamp + 3 seconds);

        linearAccrual.drip(rateId);

        (updatedRate,) = linearAccrual.rates(rateId);
        uint256 ratePow4 =
            rateSquare * uint256(rate) / (10 ** 27) * uint256(rate) / (10 ** 27) * uint256(rate) / (10 ** 27);
        assertEq(uint256(updatedRate), ratePow4, "Rate should be ^4 after four periods");
    }
}

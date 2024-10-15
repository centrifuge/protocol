// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/LinearAccrual.sol";
import "src/interfaces/ILinearAccrual.sol";
import "src/Compounding.sol";

contract LinearAccrualTest is Test {
    LinearAccrual linearAccrual;

    event NewRateId(bytes32 rateId, uint128 rate, CompoundingPeriod period);
    event RateAccumulated(bytes32 rateId, uint128 rate, uint256 periodsPassed);

    function setUp() public {
        linearAccrual = new LinearAccrual();
        vm.warp(1 days);
    }

    function testGetRateId(uint128 rate) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));

        // Compounding schedule irrelevant since test does not require dripping
        CompoundingPeriod period = CompoundingPeriod.Quarterly;
        vm.expectEmit(true, true, true, true);
        emit NewRateId(keccak256(abi.encode(Group(rate, period))), rate, period);
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        (uint128 ratePerPeriod, CompoundingPeriod retrievedPeriod) = linearAccrual.groups(rateId);
        assertEq(ratePerPeriod, rate, "Rate per period mismatch");
        assertEq(uint256(retrievedPeriod), uint256(period), "Period mismatch");

        (uint128 accumulatedRate, uint64 lastUpdated) = linearAccrual.rates(rateId);
        assertEq(accumulatedRate, rate, "Initial accumulated rate mismatch");
        assertEq(uint256(lastUpdated), block.timestamp, "Last updated mismatch");
    }

    function testIncreaseNormalizedDebt(uint128 rate, uint128 prevNormalizedDebt, uint128 debtIncrease) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        debtIncrease = uint128(bound(debtIncrease, 0, 10 ** 20));
        vm.assume(prevNormalizedDebt < type(uint128).max - debtIncrease / rate);

        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.getRateId(rate, CompoundingPeriod.Quarterly);

        uint128 newDebt = linearAccrual.increaseNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
        uint128 expectedDebt = prevNormalizedDebt + (debtIncrease / rate);
        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testDecreaseNormalizedDebt(uint128 rate, uint128 prevNormalizedDebt, uint128 debtDecrease) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        debtDecrease = uint128(bound(debtDecrease, 0, 10 ** 20));
        prevNormalizedDebt = uint128(bound(prevNormalizedDebt, debtDecrease / rate, 10 ** 20));

        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.getRateId(rate, CompoundingPeriod.Quarterly);

        uint128 newDebt = linearAccrual.decreaseNormalizedDebt(rateId, prevNormalizedDebt, debtDecrease);
        uint128 expectedDebt = prevNormalizedDebt - (debtDecrease / rate);

        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testRenormalizeDebt(uint128 oldRate, uint128 newRate, uint128 prevNormalizedDebt) public {
        oldRate = uint128(bound(oldRate, 10 ** 10, 10 ** 20));
        newRate = uint128(bound(newRate, 10 ** 10, 10 ** 20));

        // Compounding schedule irrelevant since test does not require dripping
        CompoundingPeriod period = CompoundingPeriod.Quarterly;
        bytes32 oldRateId = linearAccrual.getRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.getRateId(newRate, period);

        uint256 oldDebt = linearAccrual.debt(oldRateId, prevNormalizedDebt);
        uint256 expectedNewNormalizedDebt = oldDebt / newRate;
        uint128 newNormalizedDebt = linearAccrual.renormalizeDebt(oldRateId, newRateId, prevNormalizedDebt);
        assertEq(newNormalizedDebt, expectedNewNormalizedDebt, "Incorrect renormalized debt");
    }

    function testDebtCalculation(uint128 rate, uint128 normalizedDebt) public {
        uint128 precision = MathLib.toUint128(MathLib.One18);
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));

        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.getRateId(rate, CompoundingPeriod.Quarterly);

        uint256 currentDebt = linearAccrual.debt(rateId, normalizedDebt);
        uint256 expectedDebt = uint256(normalizedDebt) * rate / precision;
        assertEq(currentDebt, expectedDebt, "Incorrect debt calculation");
    }

    function testDripUpdatesRate(uint128 rate) public {
        rate = uint128(bound(rate, MathLib.One18 / 1000, MathLib.One18 * 100));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Pass zero periods
        linearAccrual.drip(rateId);
        (uint128 rateZeroPeriods,) = linearAccrual.rates(rateId);
        assertEq(rateZeroPeriods, rate, "Rate should be same after no passed periods");

        // Pass one period
        (, uint64 initialLastUpdated) = linearAccrual.rates(rateId);
        vm.warp(initialLastUpdated + 1 seconds);
        uint256 rateSquare = MathLib.mulDiv(uint256(rate), uint256(rate), MathLib.One18);
        vm.expectEmit(true, true, true, true);
        emit RateAccumulated(rateId, uint128(rateSquare), 1);
        linearAccrual.drip(rateId);
        (uint128 rateAfterTwoPeriods,) = linearAccrual.rates(rateId);
        assertEq(uint256(rateAfterTwoPeriods), rateSquare, "Rate should be ^2 after one passed period");

        // Pass 2 more periods
        vm.warp(block.timestamp + 2 seconds);
        uint256 ratePow4 = MathLib.mulDiv(rateSquare, rateSquare, MathLib.One18);
        linearAccrual.drip(rateId);
        (uint128 rateAfter4Periods,) = linearAccrual.rates(rateId);
        assertApproxEqAbs(uint256(rateAfter4Periods), ratePow4, 10 ** 4, "Rate should be ^4 after 3 passed periods");
    }
}

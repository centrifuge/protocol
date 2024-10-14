// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/LinearAccrual.sol";
import "src/interfaces/ILinearAccrual.sol";
import "src/Compounding.sol";

contract TestLinearAccrual is Test {
    LinearAccrual linearAccrual;
    // TODO: Explore replacing with random rate
    /// @dev 1.9753462 with 27 decimal precision
    uint128 constant RATE_128 = 19_753_462 * 10 ** 20;
    /// @dev 1.9753462 with 27 decimal precision
    uint256 constant RATE_256 = uint256(RATE_128);

    event NewRateId(bytes32 rateId, uint128 rate, CompoundingPeriod period);
    event RateAccumulated(bytes32 rateId, uint128 rate, uint256 periodsPassed);

    function setUp() public {
        linearAccrual = new LinearAccrual();
        vm.warp(1 days);
    }

    function testGetRateId() public {
        uint128 rate = 5 * 10 ** 18;
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

    function testIncreaseNormalizedDebt() public {
        uint128 rate = 5 * 10 ** 18;
        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.getRateId(rate, CompoundingPeriod.Quarterly);

        uint128 prevNormalizedDebt = 100 * 10 ** 18;
        uint128 debtIncrease = 50 * 10 ** 18;

        uint128 newDebt = linearAccrual.increaseNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
        uint128 expectedDebt = prevNormalizedDebt + (debtIncrease / rate);
        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testDecreaseNormalizedDebt() public {
        uint128 rate = 5 * 10 ** 18;
        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.getRateId(rate, CompoundingPeriod.Quarterly);

        uint128 prevNormalizedDebt = 100 * 10 ** 18;
        uint128 debtDecrease = 20 * 10 ** 18;

        uint128 newDebt = linearAccrual.decreaseNormalizedDebt(rateId, prevNormalizedDebt, debtDecrease);
        uint128 expectedDebt = prevNormalizedDebt - (debtDecrease / rate);

        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testRenormalizeDebt() public {
        uint128 oldRate = 5 * 10 ** 18;
        uint128 newRate = 10 * 10 ** 18;
        // Compounding schedule irrelevant since test does not require dripping
        CompoundingPeriod period = CompoundingPeriod.Quarterly;
        bytes32 oldRateId = linearAccrual.getRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.getRateId(newRate, period);

        uint128 prevNormalizedDebt = 100 * 10 ** 18;

        uint256 oldDebt = linearAccrual.debt(oldRateId, prevNormalizedDebt);
        uint256 expectedNewNormalizedDebt = oldDebt / newRate;
        uint128 newNormalizedDebt = linearAccrual.renormalizeDebt(oldRateId, newRateId, prevNormalizedDebt);
        assertEq(newNormalizedDebt, expectedNewNormalizedDebt, "Incorrect renormalized debt");
    }

    function testDebtCalculation() public {
        uint128 precision = 10 ** 27;
        uint128 rate = 5 * precision;
        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.getRateId(rate, CompoundingPeriod.Quarterly);

        uint128 normalizedDebt = 100 * precision;

        uint256 currentDebt = linearAccrual.debt(rateId, normalizedDebt);
        uint256 expectedDebt = uint256(normalizedDebt) * rate / precision;
        assertEq(currentDebt, expectedDebt, "Incorrect debt calculation");
    }

    function testDripUpdatesRate() public {
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.getRateId(RATE_128, period);

        // Pass zero periods
        linearAccrual.drip(rateId);
        (uint128 rateZeroPeriods,) = linearAccrual.rates(rateId);
        assertEq(rateZeroPeriods, RATE_128, "Rate should be same after no passed periods");

        // Pass one period
        (, uint64 initialLastUpdated) = linearAccrual.rates(rateId);
        vm.warp(initialLastUpdated + 1 seconds);
        uint256 rateSquare = MathLib.mulDiv(RATE_256, RATE_256, MathLib.One27);
        vm.expectEmit(true, true, true, true);
        emit RateAccumulated(rateId, uint128(rateSquare), 1);
        linearAccrual.drip(rateId);
        (uint128 rateAfterTwoPeriods,) = linearAccrual.rates(rateId);
        assertEq(uint256(rateAfterTwoPeriods), rateSquare, "Rate should be quadratic after one passed period");

        // Pass 3 more periods
        vm.warp(block.timestamp + 3 seconds);
        uint256 ratePow5 = MathLib.mulDiv(
            MathLib.mulDiv(MathLib.mulDiv(rateSquare, RATE_256, MathLib.One27), RATE_256, MathLib.One27),
            RATE_256,
            MathLib.One27,
            // TODO(@review): Discuss whether rounding up here accepted to fix being one off
            MathLib.Rounding.Up
        );
        vm.expectEmit(true, true, true, true);
        emit RateAccumulated(rateId, uint128(ratePow5), 3);
        linearAccrual.drip(rateId);
        (uint128 rateAfter4Periods,) = linearAccrual.rates(rateId);
        assertEq(uint256(rateAfter4Periods), ratePow5, "Rate should be ^5 after four passed periods");
    }
}

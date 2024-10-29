// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LinearAccrual, Group} from "src/LinearAccrual.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {ILinearAccrual} from "src/interfaces/ILinearAccrual.sol";
import "src/Compounding.sol";

contract LinearAccrualTest is Test {
    using MathLib for uint256;

    LinearAccrual linearAccrual;

    function setUp() public {
        linearAccrual = new LinearAccrual();
        vm.warp(1 days);
    }

    function testGetRateId(uint128 rate, uint8 periodInt) public view {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 rateId = linearAccrual.getRateId(rate, period);
        assertEq(keccak256(abi.encode(Group(rate, period))), rateId, "Rate id mismatch");
    }

    function testRegisterRateId(uint128 rate, uint8 periodInt) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        vm.expectEmit(true, true, true, true);
        emit ILinearAccrual.NewRateId(keccak256(abi.encode(Group(rate, period))), rate, period);
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        (uint128 ratePerPeriod, CompoundingPeriod retrievedPeriod) = linearAccrual.groups(rateId);
        assertEq(ratePerPeriod, rate, "Rate per period mismatch");
        assertEq(uint256(retrievedPeriod), uint256(period), "Period mismatch");

        (uint128 accumulatedRate, uint64 lastUpdated) = linearAccrual.rates(rateId);
        assertEq(accumulatedRate, rate, "Initial accumulated rate mismatch");
        assertEq(uint256(lastUpdated), block.timestamp, "Last updated mismatch");
    }

    function testRegisterRateIdReverts(uint128 rate, uint8 periodInt) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdExists.selector, rateId, rate, period));
        linearAccrual.registerRateId(rate, period);
    }

    function testGetIncreasedNormalizedDebt(
        uint128 rate,
        uint128 prevNormalizedDebt,
        uint128 debtIncrease,
        uint8 periodInt
    ) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        debtIncrease = uint128(bound(debtIncrease, 0, 10 ** 20));
        vm.assume(prevNormalizedDebt < type(uint128).max - debtIncrease / rate);
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        uint128 newDebt = linearAccrual.getIncreasedNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
        uint128 expectedDebt = prevNormalizedDebt + (debtIncrease / rate);
        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert();
        linearAccrual.getIncreasedNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
    }

    function testGetIncreasedNormalizedDebtReverts(uint128 rate, uint8 periodInt) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, rateId));
        linearAccrual.getIncreasedNormalizedDebt(rateId, 0, 0);

        linearAccrual.registerRateId(rate, period);
        vm.warp(block.timestamp + 1 seconds);

        // Update missing after advancing blocks
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, rateId, block.timestamp - 1 seconds)
        );
        linearAccrual.getIncreasedNormalizedDebt(rateId, 0, 0);
    }

    function testGetDecreasedNormalizedDebt(
        uint128 rate,
        uint128 prevNormalizedDebt,
        uint128 debtDecrease,
        uint8 periodInt
    ) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        debtDecrease = uint128(bound(debtDecrease, 0, 10 ** 20));
        prevNormalizedDebt = uint128(bound(prevNormalizedDebt, debtDecrease / rate, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        uint128 newDebt = linearAccrual.getDecreasedNormalizedDebt(rateId, prevNormalizedDebt, debtDecrease);
        uint128 expectedDebt = prevNormalizedDebt - (debtDecrease / rate);

        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testGetDecreasedNormalizedDebtReverts(uint128 rate, uint8 periodInt) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, rateId));
        linearAccrual.getDecreasedNormalizedDebt(rateId, 0, 0);

        linearAccrual.registerRateId(rate, period);
        vm.warp(block.timestamp + 1 seconds);

        // Update missing after advancing blocks
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, rateId, block.timestamp - 1 seconds)
        );
        linearAccrual.getDecreasedNormalizedDebt(rateId, 0, 0);
    }

    function testGetRenormalizedDebt(uint128 oldRate, uint128 newRate, uint128 prevNormalizedDebt, uint8 periodInt)
        public
    {
        vm.assume(oldRate != newRate);
        oldRate = uint128(bound(oldRate, 10 ** 10, 10 ** 20));
        newRate = uint128(bound(newRate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 oldRateId = linearAccrual.registerRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.registerRateId(newRate, period);

        uint256 oldDebt = linearAccrual.debt(oldRateId, prevNormalizedDebt);
        uint256 expectedNewNormalizedDebt = oldDebt / newRate;
        uint128 newNormalizedDebt = linearAccrual.getRenormalizedDebt(oldRateId, newRateId, prevNormalizedDebt);
        assertEq(newNormalizedDebt, expectedNewNormalizedDebt, "Incorrect renormalized debt");
    }

    function testGetRenormalizedDebtReverts(uint128 oldRate, uint128 newRate) public {
        vm.assume(oldRate != newRate);
        oldRate = uint128(bound(oldRate, 10 ** 10, 10 ** 20));
        newRate = uint128(bound(newRate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 oldRateId = linearAccrual.getRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.getRateId(newRate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, oldRateId));
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 0);

        linearAccrual.registerRateId(oldRate, period);
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, newRateId));
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 1);

        linearAccrual.registerRateId(newRate, period);
        vm.warp(block.timestamp + 1 seconds);

        // Update missing after advancing blocks
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, oldRateId, block.timestamp - 1 seconds)
        );
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 2);

        linearAccrual.drip(oldRateId);
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, newRateId, block.timestamp - 1 seconds)
        );
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 3);
    }

    function testDebt(uint128 rate, uint128 normalizedDebt, uint8 periodInt) public {
        uint128 precision = MathLib.One18.toUint128();
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        uint256 currentDebt = linearAccrual.debt(rateId, normalizedDebt);
        uint256 expectedDebt = uint256(normalizedDebt) * rate / precision;
        assertEq(currentDebt, expectedDebt, "Incorrect debt calculation");
    }

    function testDebtReverts(uint128 rate, uint8 periodInt) public {
        rate = uint128(bound(rate, 10 ** 10, 10 ** 20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, rateId));
        linearAccrual.debt(rateId, 0);

        linearAccrual.registerRateId(rate, period);
        vm.warp(block.timestamp + 1 seconds);

        // Update missing after advancing blocks
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, rateId, block.timestamp - 1 seconds)
        );
        linearAccrual.debt(rateId, 0);
    }

    function testDrip(uint128 rate) public {
        rate = uint128(bound(rate, MathLib.One18 / 1000, MathLib.One18 * 100));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        // Pass zero periods
        linearAccrual.drip(rateId);
        (uint128 rateZeroPeriods,) = linearAccrual.rates(rateId);
        assertEq(rateZeroPeriods, rate, "Rate should be same after no passed periods");

        // Pass one period
        (, uint64 initialLastUpdated) = linearAccrual.rates(rateId);
        vm.warp(initialLastUpdated + 1 seconds);
        uint256 rateSquare = uint256(rate).mulDiv(uint256(rate), MathLib.One18);
        vm.expectEmit(true, true, true, true);
        emit ILinearAccrual.RateAccumulated(rateId, rateSquare.toUint128(), 1);
        linearAccrual.drip(rateId);
        (uint128 rateAfterTwoPeriods,) = linearAccrual.rates(rateId);
        assertEq(uint256(rateAfterTwoPeriods), rateSquare, "Rate should be ^2 after one passed period");

        // Pass 2 more periods
        vm.warp(block.timestamp + 2 seconds);
        uint256 ratePow4 = rateSquare.mulDiv(rateSquare, MathLib.One18);
        linearAccrual.drip(rateId);
        (uint128 rateAfter4Periods,) = linearAccrual.rates(rateId);
        assertApproxEqAbs(uint256(rateAfter4Periods), ratePow4, 10 ** 4, "Rate should be ^4 after 3 passed periods");
    }

    function testDripReverts(uint128 rate) public {
        rate = uint128(bound(rate, MathLib.One18 / 1000, MathLib.One18 * 1000));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, rateId));
        linearAccrual.drip(rateId);
    }
}

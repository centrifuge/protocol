// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LinearAccrual, Group} from "src/LinearAccrual.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {ILinearAccrual} from "src/interfaces/ILinearAccrual.sol";
import {CompoundingPeriod} from "src/libraries/Compounding.sol";
import {d18, D18, mulInt} from "src/types/D18.sol";

contract LinearAccrualTest is Test {
    using MathLib for uint256;
    using MathLib for uint128;
    using MathLib for int128;

    LinearAccrual linearAccrual;

    function setUp() public {
        linearAccrual = new LinearAccrual();
        vm.warp(1 days);
    }

    function testFuzzGetRateId(uint128 _rate, uint8 _period) public view {
        D18 rate = d18(uint128(bound(_rate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));

        bytes32 rateId = linearAccrual.getRateId(rate, period);
        assertEq(keccak256(abi.encode(Group(rate, period))), rateId, "Rate id mismatch");
    }

    function testFuzzRegisterRateId(uint128 _rate, uint8 _period) public {
        D18 rate = d18(uint128(bound(_rate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));

        vm.expectEmit(true, true, true, true);
        emit ILinearAccrual.NewRateId(keccak256(abi.encode(Group(rate, period))), rate, period);
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        (D18 ratePerPeriod, CompoundingPeriod retrievedPeriod) = linearAccrual.groups(rateId);
        assertEq(ratePerPeriod.inner(), rate.inner(), "Rate per period mismatch");
        assertEq(uint8(retrievedPeriod), uint8(period), "Period mismatch");

        (D18 accumulatedRate, uint64 lastUpdated) = linearAccrual.rates(rateId);
        assertEq(accumulatedRate.inner(), rate.inner(), "Initial accumulated rate mismatch");
        assertEq(lastUpdated, uint64(block.timestamp), "Last updated mismatch");
    }

    function testRegisterRateIdReverts(uint128 _rate, uint8 _period) public {
        D18 rate = d18(uint128(bound(_rate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdExists.selector, rateId, rate, period));
        linearAccrual.registerRateId(rate, period);
    }

    function testFuzzGetNormalizedDebtNoChange(
        uint128 _rate,
        uint128 prevNormalizedDebtUnsigned,
        bool isNegativeDebt,
        uint8 _period
    ) public {
        D18 rate = d18(uint128(bound(_rate, 1e10, 1e20)));
        prevNormalizedDebtUnsigned =
            uint128(bound(prevNormalizedDebtUnsigned, 0, uint128(type(int128).max) / rate.inner()));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));

        int128 prevNormalizedDebt =
            isNegativeDebt ? -(prevNormalizedDebtUnsigned).toInt128() : prevNormalizedDebtUnsigned.toInt128();

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        int128 newDebt = linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, 0);
        assertEq(newDebt, prevNormalizedDebt, "Incorrect new normalized debt with 0 change");
    }

    function testGetModiefiedNormalizedDebt() public {
        D18 rate = d18(uint128(15e16)); // 0.15
        CompoundingPeriod period = CompoundingPeriod.Daily;
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        // Case 1: positive debt, positive change
        int128 prevNormalizedDebt = 1e21;
        int128 change = 3e19;
        // 1e21 + (30/0.15)e18
        int128 newDebt = linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, change);
        assertEq(newDebt, 1e21 + 2e20, "Incorrect new normalized debt with hardcoded change (case 1)");

        // Case 2: positive debt, negative change
        change = -3e19;
        newDebt = linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, change);
        assertEq(newDebt, 1e21 - 2e20, "Incorrect new normalized debt with hardcoded change (case 2)");

        // Case 3: negative debt, negative change
        prevNormalizedDebt = -1e21;
        newDebt = linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, change);
        assertEq(newDebt, -1e21 - 2e20, "Incorrect new normalized debt with hardcoded change (case 3)");

        // Case 4: negative debt, positive change
        change = 3e19;
        newDebt = linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, change);
        assertEq(newDebt, -1e21 + 2e20, "Incorrect new normalized debt with hardcoded change (case 4)");
    }

    function testFuzzGetModifiedNormalizedDebt(
        uint128 _rate,
        uint128 _prevNormalizedDebtUnsigned,
        uint128 _debtChangeUnsigned,
        bool isNegativeDebt,
        bool isNegativeChange,
        uint8 _period
    ) public {
        D18 rate = d18(uint128(bound(_rate, 1e4, 1e20)));
        uint128 prevNormalizedDebtUnsigned =
            uint128(bound(_prevNormalizedDebtUnsigned, 0, uint128(type(int128).max) / rate.inner()));
        uint128 debtChangeUnsigned = uint128(bound(_debtChangeUnsigned, 0, uint128(type(int128).max)) / 1e18); // [0,
            // ~1.74e19]
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));

        int128 signDebt = isNegativeDebt ? -1 : int128(1);
        int128 signChange = isNegativeChange ? -1 : int128(1);
        int128 prevNormalizedDebt = signDebt * prevNormalizedDebtUnsigned.toInt128();
        int128 debtChanged = signChange * debtChangeUnsigned.toInt128();

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        int128 newDebt = linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, debtChanged);
        int128 expectedDebt = prevNormalizedDebt
            + signChange * uint256(debtChangeUnsigned).mulDiv(1e18, rate.inner()).toUint128().toInt128();
        assertEq(newDebt, expectedDebt, "Incorrect fuzzed new normalized debt");

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert();
        linearAccrual.getModifiedNormalizedDebt(rateId, prevNormalizedDebt, debtChanged);
    }

    function testGetRenormalizedDebt() public {
        D18 oldRate = d18(uint128(15e16)); // 0.15
        D18 newRate = d18(uint128(45e16)); // 0.45
        CompoundingPeriod period = CompoundingPeriod.Daily;
        bytes32 oldRateId = linearAccrual.registerRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.registerRateId(newRate, period);

        int128 newNormalizedDebt = linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 3e10);
        assertEq(newNormalizedDebt, 1e10, "Incorrect hardcoded renormalized debt");
    }

    function testFuzzGetRenormalizedDebtFuzz(
        uint128 _oldRate,
        uint128 _newRate,
        uint128 prevNormalizedDebtUnsigned,
        bool isNegativeDebt,
        uint8 _period
    ) public {
        vm.assume(_oldRate != _newRate);
        D18 oldRate = d18(uint128(bound(_oldRate, 1e10, 1e20)));
        D18 newRate = d18(uint128(bound(_newRate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));
        prevNormalizedDebtUnsigned =
            uint128(bound(prevNormalizedDebtUnsigned, 0, uint128(type(int128).max) / newRate.inner()));

        int128 signDebt = isNegativeDebt ? -1 : int128(1);
        int128 prevNormalizedDebt = signDebt * prevNormalizedDebtUnsigned.toInt128();
        bytes32 oldRateId = linearAccrual.registerRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.registerRateId(newRate, period);

        int128 oldDebt = linearAccrual.debt(oldRateId, prevNormalizedDebt);
        int128 expectedNewNormalizedDebt =
            signDebt * uint256(uint128(signDebt * oldDebt)).mulDiv(1e18, newRate.inner()).toUint128().toInt128();
        int128 newNormalizedDebt = linearAccrual.getRenormalizedDebt(oldRateId, newRateId, prevNormalizedDebt);
        assertEq(newNormalizedDebt, expectedNewNormalizedDebt, "Incorrect fuzzed renormalized debt");
    }

    function testFuzzGetRenormalizedDebtReverts(uint128 _oldRate, uint128 _newRate) public {
        vm.assume(_oldRate != _newRate);
        D18 oldRate = d18(uint128(bound(_oldRate, 1e10, 1e20)));
        D18 newRate = d18(uint128(bound(_newRate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 oldRateId = linearAccrual.getRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.getRateId(newRate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, newRateId));
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 1);
        linearAccrual.registerRateId(newRate, period);

        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, oldRateId));
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 0);
        linearAccrual.registerRateId(oldRate, period);

        vm.warp(block.timestamp + 1 seconds);

        // Update missing after advancing blocks
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, newRateId, block.timestamp - 1 seconds)
        );
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 3);

        linearAccrual.drip(newRateId);
        vm.expectRevert(
            abi.encodeWithSelector(ILinearAccrual.RateIdOutdated.selector, oldRateId, block.timestamp - 1 seconds)
        );
        linearAccrual.getRenormalizedDebt(oldRateId, newRateId, 2);
    }

    function testFuzzDebt(uint128 _rate, uint128 normalizedDebtUnsigned, bool isNegativeDebt, uint8 _period) public {
        uint128 precision = 1e18;
        D18 rate = d18(uint128(bound(_rate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));
        normalizedDebtUnsigned = uint128(bound(normalizedDebtUnsigned, 0, uint128(type(int128).max) / rate.inner()));
        int128 sign = isNegativeDebt ? -1 : int128(1);
        int128 normalizedDebt = sign * normalizedDebtUnsigned.toInt128();

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        int128 currentDebt = linearAccrual.debt(rateId, normalizedDebt);
        uint128 expectedDebtUnsigned = normalizedDebtUnsigned * rate.inner() / precision;

        assertEq(currentDebt, sign * expectedDebtUnsigned.toInt128(), "Incorrect debt calculation");
    }

    function testFuzzDebtReverts(uint128 _rate, uint8 _period) public {
        D18 rate = d18(uint128(bound(_rate, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(_period, 0, 1));
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

    function testFuzzDrip(uint128 _rate) public {
        D18 rate = d18(uint128(bound(_rate, 1e15, 1e20)));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        // Pass zero periods
        linearAccrual.drip(rateId);
        (D18 rateZeroPeriods,) = linearAccrual.rates(rateId);
        assertEq(rateZeroPeriods.inner(), rate.inner(), "Rate should be same after no passed periods");

        // Pass one period
        (, uint64 initialLastUpdated) = linearAccrual.rates(rateId);
        vm.warp(initialLastUpdated + 1 seconds);
        D18 rateSquare = d18(rate.mulInt(rate.inner()));
        vm.expectEmit(true, true, true, true);
        emit ILinearAccrual.RateAccumulated(rateId, rateSquare, 1);
        linearAccrual.drip(rateId);
        (D18 rateAfterTwoPeriods,) = linearAccrual.rates(rateId);
        assertEq(rateAfterTwoPeriods.inner(), rateSquare.inner(), "Rate should be ^2 after one passed period");

        // Pass 2 more periods
        vm.warp(block.timestamp + 2 seconds);
        uint128 ratePow4 = rateSquare.mulInt(rateSquare.inner());
        linearAccrual.drip(rateId);
        (D18 rateAfter4Periods,) = linearAccrual.rates(rateId);
        assertApproxEqAbs(rateAfter4Periods.inner(), ratePow4, 10 ** 4, "Rate should be ^4 after 3 passed periods");
    }

    function testFuzzDripReverts(uint128 _rate) public {
        D18 rate = d18(uint128(bound(_rate, 1e15, 1e21)));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, rateId));
        linearAccrual.drip(rateId);
    }
}

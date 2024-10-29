// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LinearAccrual, Group} from "src/LinearAccrual.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {ILinearAccrual} from "src/interfaces/ILinearAccrual.sol";
import "src/Compounding.sol";
import {d18, D18, mulInt} from "src/types/D18.sol";

contract LinearAccrualTest is Test {
    using MathLib for uint256;

    LinearAccrual linearAccrual;

    function setUp() public {
        linearAccrual = new LinearAccrual();
        vm.warp(1 days);
    }

    function testGetRateId(uint128 rate128, uint8 periodInt) public view {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 rateId = linearAccrual.getRateId(rate, period);
        assertEq(keccak256(abi.encode(Group(rate, period))), rateId, "Rate id mismatch");
    }

    function testRegisterRateId(uint128 rate128, uint8 periodInt) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        vm.expectEmit(true, true, true, true);
        emit ILinearAccrual.NewRateId(keccak256(abi.encode(Group(rate, period))), rate, period);
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        (D18 ratePerPeriod, CompoundingPeriod retrievedPeriod) = linearAccrual.groups(rateId);
        assertEq(ratePerPeriod.inner(), rate.inner(), "Rate per period mismatch");
        assertEq(uint256(retrievedPeriod), uint256(period), "Period mismatch");

        (D18 accumulatedRate, uint64 lastUpdated) = linearAccrual.rates(rateId);
        assertEq(accumulatedRate.inner(), rate.inner(), "Initial accumulated rate mismatch");
        assertEq(uint256(lastUpdated), block.timestamp, "Last updated mismatch");
    }

    function testRegisterRateIdReverts(uint128 rate128, uint8 periodInt) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdExists.selector, rateId, rate, period));
        linearAccrual.registerRateId(rate, period);
    }

    function testGetIncreasedNormalizedDebt(
        uint128 rate128,
        uint128 prevNormalizedDebt,
        uint128 debtIncrease,
        uint8 periodInt
    ) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
        debtIncrease = uint128(bound(debtIncrease, 0, 1e20));
        vm.assume(prevNormalizedDebt < type(uint128).max - debtIncrease / rate.inner());
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        uint128 newDebt = linearAccrual.getIncreasedNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
        uint128 expectedDebt = prevNormalizedDebt + (debtIncrease / rate.inner());
        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");

        vm.warp(block.timestamp + 1 seconds);
        vm.expectRevert();
        linearAccrual.getIncreasedNormalizedDebt(rateId, prevNormalizedDebt, debtIncrease);
    }

    function testGetIncreasedNormalizedDebtReverts(uint128 rate128, uint8 periodInt) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
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
        uint128 rate128,
        uint128 prevNormalizedDebt,
        uint128 debtDecrease,
        uint8 periodInt
    ) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
        debtDecrease = uint128(bound(debtDecrease, 0, 1e20));
        prevNormalizedDebt = uint128(bound(prevNormalizedDebt, debtDecrease / rate.inner(), 1e20));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        // Compounding schedule irrelevant since test does not require dripping
        bytes32 rateId = linearAccrual.registerRateId(rate, period);

        uint128 newDebt = linearAccrual.getDecreasedNormalizedDebt(rateId, prevNormalizedDebt, debtDecrease);
        uint128 expectedDebt = prevNormalizedDebt - (debtDecrease / rate.inner());

        assertEq(newDebt, expectedDebt, "Incorrect new normalized debt");
    }

    function testGetDecreasedNormalizedDebtReverts(uint128 rate128, uint8 periodInt) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
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

    function testGetRenormalizedDebt(
        uint128 oldRate128,
        uint128 newRate128,
        uint128 prevNormalizedDebt,
        uint8 periodInt
    ) public {
        vm.assume(oldRate128 != newRate128);
        D18 oldRate = d18(uint128(bound(oldRate128, 1e10, 1e20)));
        D18 newRate = d18(uint128(bound(newRate128, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 oldRateId = linearAccrual.registerRateId(oldRate, period);
        bytes32 newRateId = linearAccrual.registerRateId(newRate, period);

        uint256 oldDebt = linearAccrual.debt(oldRateId, prevNormalizedDebt);
        uint256 expectedNewNormalizedDebt = oldDebt / newRate.inner();
        uint128 newNormalizedDebt = linearAccrual.getRenormalizedDebt(oldRateId, newRateId, prevNormalizedDebt);
        assertEq(newNormalizedDebt, expectedNewNormalizedDebt, "Incorrect renormalized debt");
    }

    function testGetRenormalizedDebtReverts(uint128 oldRate128, uint128 newRate128) public {
        vm.assume(oldRate128 != newRate128);
        D18 oldRate = d18(uint128(bound(oldRate128, 1e10, 1e20)));
        D18 newRate = d18(uint128(bound(newRate128, 1e10, 1e20)));
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

    function testDebt(uint128 rate128, uint128 normalizedDebt, uint8 periodInt) public {
        uint128 precision = 1e18;
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
        CompoundingPeriod period = CompoundingPeriod(bound(periodInt, 0, 1));

        bytes32 rateId = linearAccrual.registerRateId(rate, period);
        uint256 currentDebt = linearAccrual.debt(rateId, normalizedDebt);
        uint256 expectedDebt = uint256(normalizedDebt) * rate.inner() / precision;
        assertEq(currentDebt, expectedDebt, "Incorrect debt calculation");
    }

    function testDebtReverts(uint128 rate128, uint8 periodInt) public {
        D18 rate = d18(uint128(bound(rate128, 1e10, 1e20)));
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

    function testDrip(uint128 rate128) public {
        D18 rate = d18(uint128(bound(rate128, 1e15, 1e20)));
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

    function testDripReverts(uint128 rate128) public {
        D18 rate = d18(uint128(bound(rate128, 1e15, 1e21)));
        CompoundingPeriod period = CompoundingPeriod.Secondly;
        bytes32 rateId = linearAccrual.getRateId(rate, period);

        // Registration missing
        vm.expectRevert(abi.encodeWithSelector(ILinearAccrual.RateIdMissing.selector, rateId));
        linearAccrual.drip(rateId);
    }
}

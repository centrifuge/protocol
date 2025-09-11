// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ArrayLib} from "../../../../src/misc/libraries/ArrayLib.sol";

import "forge-std/Test.sol";

contract ArrayLibTest is Test {
    using ArrayLib for *;

    int16[8] storedArray;

    function testCountPositiveValues(int16[8] memory array, uint8 valuesToCheck) public pure {
        vm.assume(valuesToCheck <= 8);

        uint8 negativeOrZero;
        for (uint256 i; i < valuesToCheck; i++) {
            if (array[i] <= 0) negativeOrZero++;
        }

        assertEq(array.countPositiveValues(valuesToCheck), valuesToCheck - negativeOrZero);
    }

    function testDecreaseFirstNValues(int16[8] memory initialArray, uint8 valuesToDecrease) public {
        vm.assume(valuesToDecrease <= 8);
        for (uint256 i; i < valuesToDecrease; i++) {
            vm.assume(initialArray[i] > type(int16).min);
        }
        storedArray = initialArray;
        storedArray.decreaseFirstNValues(valuesToDecrease);

        assertEq(uint8(int8(_sum(initialArray) - _sum(storedArray))), valuesToDecrease);
    }

    function _sum(int16[8] memory arr) internal pure returns (int256 count) {
        for (uint256 i; i < arr.length; i++) {
            count += int256(arr[i]);
        }
    }
}

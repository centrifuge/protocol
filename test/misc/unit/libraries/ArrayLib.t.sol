// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ArrayLib} from "../../../../src/misc/libraries/ArrayLib.sol";

import "forge-std/Test.sol";

contract ArrayLibTest is Test {
    // Used for testDecreaseFirstNValues (which requires storage pointers)
    int16[8] initialArray;
    int16[8] decreasedArray;

    function testCountPositiveValues(uint8 numPositives) public view {
        numPositives = uint8(bound(numPositives, 0, 8));
        int16[8] memory arr = _randomArray(numPositives);

        assertEq(ArrayLib.countPositiveValues(arr), numPositives);
    }

    function testDecreaseFirstNValues(uint8 numValuesToDecrease) public {
        numValuesToDecrease = uint8(bound(numValuesToDecrease, 0, 8));

        initialArray = _randomArray(8);
        decreasedArray = initialArray;
        uint8 numPositives = ArrayLib.countPositiveValues(initialArray);

        // Decreasing by 1 should reduce by min(numPositives, numValuesToDecrease) since zero values cannot be decreased
        ArrayLib.decreaseFirstNValues(decreasedArray, numValuesToDecrease);
        assertEq(_count(initialArray) - _count(decreasedArray), _min(numPositives, numValuesToDecrease));
    }

    function testIsEmpty(uint8 numNonZeroes) public view {
        numNonZeroes = uint8(bound(numNonZeroes, 0, 8));
        int16[8] memory arr = _randomArray(numNonZeroes);

        // Array is only empty if there are no zeros
        assertEq(ArrayLib.isEmpty(arr), numNonZeroes == 0);
    }

    function _randomArray(uint8 numNonZeroes) internal view returns (int16[8] memory arr) {
        for (uint256 i; i < numNonZeroes; i++) {
            arr[i] = _randomInt16(1, type(int16).max);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? b : a;
    }

    function _count(int16[8] memory arr) internal pure returns (uint256 count) {
        for (uint256 i; i < arr.length; i++) {
            count += uint256(uint16(arr[i]));
        }
    }

    function _randomInt16(int16 minValue, int16 maxValue) internal view returns (int16) {
        uint256 nonce = 1;

        if (maxValue == 1) {
            return 1;
        }

        int16 value =
            int16(uint256(keccak256(abi.encodePacked(block.timestamp, address(this), nonce))) % (maxValue - minValue));
        return value + minValue;
    }
}

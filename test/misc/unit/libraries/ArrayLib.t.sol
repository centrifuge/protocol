// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ArrayLib} from "../../../../src/misc/libraries/ArrayLib.sol";

import "forge-std/Test.sol";

contract ArrayLibTest is Test {
    // Used for testDecreaseFirstNValues (which requires storage pointers)
    uint16[8] initialArray;
    uint16[8] decreasedArray;

    function testCountNonZeroValues(uint8 numNonZeroes) public view {
        numNonZeroes = uint8(bound(numNonZeroes, 0, 8));
        uint16[8] memory arr = _randomArray(numNonZeroes);

        assertEq(ArrayLib.countNonZeroValues(arr), numNonZeroes);
    }

    function testDecreaseFirstNValues(uint8 numValuesToDecrease) public {
        numValuesToDecrease = uint8(bound(numValuesToDecrease, 0, 8));

        initialArray = _randomArray(8);
        decreasedArray = initialArray;
        uint8 numNonZeroes = ArrayLib.countNonZeroValues(initialArray);

        // Decreasing by 1 should reduce by min(numNonZeroes, numValuesToDecrease) since zero values cannot be decreased
        ArrayLib.decreaseFirstNValues(decreasedArray, numValuesToDecrease);
        assertEq(_count(initialArray) - _count(decreasedArray), _min(numNonZeroes, numValuesToDecrease));
    }

    function testIsEmpty(uint8 numNonZeroes) public view {
        numNonZeroes = uint8(bound(numNonZeroes, 0, 8));
        uint16[8] memory arr = _randomArray(numNonZeroes);

        // Array is only empty if there are no zeros
        assertEq(ArrayLib.isEmpty(arr), numNonZeroes == 0);
    }

    function _randomArray(uint8 numNonZeroes) internal view returns (uint16[8] memory arr) {
        for (uint256 i; i < numNonZeroes; i++) {
            arr[i] = _randomUint16(1, type(uint16).max);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? b : a;
    }

    function _count(uint16[8] memory arr) internal pure returns (uint256 count) {
        for (uint256 i; i < arr.length; i++) {
            count += uint8(arr[i]);
        }
    }

    function _randomUint16(uint16 minValue, uint16 maxValue) internal view returns (uint16) {
        uint256 nonce = 1;

        if (maxValue == 1) {
            return 1;
        }

        uint16 value =
            uint16(uint256(keccak256(abi.encodePacked(block.timestamp, address(this), nonce))) % (maxValue - minValue));
        return value + minValue;
    }
}

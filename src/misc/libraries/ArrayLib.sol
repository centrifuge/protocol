// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  ArrayLib
library ArrayLib {
    function countPositiveValues(int16[8] memory arr, uint8 numValues) internal pure returns (uint8 count) {
        for (uint256 i; i < numValues; i++) {
            if (arr[i] > 0) ++count;
        }
    }

    function decreaseFirstNValues(int16[8] storage arr, uint8 numValues, uint8 numValuesLowerZero) internal {
        for (uint256 i; i < numValues; i++) {
            if (i >= numValuesLowerZero && arr[i] <= 0) continue;
            arr[i] -= 1;
        }
    }
}

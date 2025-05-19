// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  ArrayLib
library ArrayLib {
    error InvalidValues();

    function countNonZeroValues(uint16[8] memory arr) internal pure returns (uint8 count) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] != 0) ++count;
        }
    }

    function decreaseFirstNValues(uint16[8] storage arr, uint8 numValues) internal {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (numValues == 0) return;

            if (arr[i] != 0) {
                arr[i] -= 1;
                numValues--;
            }
        }

        require(numValues == 0, InvalidValues());
    }

    function isEmpty(uint16[8] memory arr) internal pure returns (bool) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] != 0) return false;
        }
        return true;
    }
}

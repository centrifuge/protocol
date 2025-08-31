// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  ArrayLib
library ArrayLib {
    error InvalidValues();

    function countPositiveValues(int16[8] memory arr) internal pure returns (uint8 count) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] > 0) ++count;
        }
    }

    function decreaseFirstNValues(int16[8] storage arr, uint8 numValues) internal {
        if (numValues == 0) return;

        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            arr[i] -= 1;
            numValues--;
        }

        require(numValues == 0, InvalidValues());
    }

    function isEmpty(int16[8] memory arr) internal pure returns (bool) {
        uint256 elementsCount = arr.length;
        for (uint256 i; i < elementsCount; i++) {
            if (arr[i] != 0) return false;
        }
        return true;
    }
}

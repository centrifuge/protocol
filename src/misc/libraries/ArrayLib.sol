// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  ArrayLib
library ArrayLib {
    function countPositiveValues(int16[8] memory arr, uint8 numValues) internal pure returns (uint8 count) {
        for (uint256 i; i < numValues; i++) {
            if (arr[i] > 0) ++count;
        }
    }

    function decreaseFirstNValues(int16[8] storage arr, uint8 numValues) internal {
        for (uint256 i; i < numValues; i++) {
            arr[i] -= 1;
        }
    }

    /// @dev Removes `count` entries starting at `from`, keeping the order of the rest.
    function remove(uint96[] storage arr, uint256 from, uint256 count) internal {
        uint256 length = arr.length;
        for (uint256 i = from + count; i < length; i++) {
            arr[i - count] = arr[i];
        }
        for (uint256 i; i < count; i++) {
            arr.pop();
        }
    }
}

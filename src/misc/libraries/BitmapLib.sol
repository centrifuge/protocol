// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  BitmapLib
library BitmapLib {
    function withBit(uint256 bitmap, uint256 index, bool isTrue) internal pure returns (uint256) {
        if (isTrue) {
            return bitmap | (uint256(1) << index);
        }

        return bitmap & ~(uint256(1) << index);
    }

    function getBit(uint256 bitmap, uint256 index) internal pure returns (bool) {
        uint256 bitAtIndex = uint256(bitmap & (1 << index));
        return bitAtIndex != 0;
    }
}

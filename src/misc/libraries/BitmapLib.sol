// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  BitmapLib
library BitmapLib {
    function withBit(uint128 bitmap, uint128 index, bool isTrue) internal pure returns (uint128) {
        if (isTrue) {
            return bitmap | (uint128(1) << index);
        }

        return bitmap & ~(uint128(1) << index);
    }

    function getBit(uint128 bitmap, uint128 index) internal pure returns (bool) {
        uint128 bitAtIndex = uint128(bitmap & (1 << index));
        return bitAtIndex != 0;
    }
}

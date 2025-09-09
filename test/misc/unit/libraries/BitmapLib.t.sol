// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BitmapLib} from "../../../../src/misc/libraries/BitmapLib.sol";

import "forge-std/Test.sol";

contract BitmapLibTest is Test {
    function testBitSetTrue(uint8 index) public pure {
        uint256 bitmap = 0;

        uint256 result = BitmapLib.withBit(bitmap, index, true);
        uint256 expected = 1 << index;

        assertEq(result, expected);
        assertTrue(BitmapLib.getBit(result, index));
    }

    function testBitSetFalse(uint8 index) public pure {
        uint256 bitmap = type(uint256).max; // All bits set to 1

        uint256 result = BitmapLib.withBit(bitmap, index, false);
        uint256 expected = type(uint256).max & ~(uint256(1) << index);

        assertEq(result, expected);
        assertFalse(BitmapLib.getBit(result, index));
    }

    function testBitMultiple() public pure {
        uint256 bitmap = 0;

        bitmap = BitmapLib.withBit(bitmap, 0, true);
        bitmap = BitmapLib.withBit(bitmap, 2, true);
        bitmap = BitmapLib.withBit(bitmap, 4, true);
        bitmap = BitmapLib.withBit(bitmap, 6, true);

        uint256 expected = (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6);
        assertEq(bitmap, expected);
        assertTrue(BitmapLib.getBit(bitmap, 0));
        assertTrue(BitmapLib.getBit(bitmap, 2));
        assertTrue(BitmapLib.getBit(bitmap, 4));
        assertTrue(BitmapLib.getBit(bitmap, 6));

        bitmap = BitmapLib.withBit(bitmap, 2, false);
        expected = (1 << 0) | (1 << 4) | (1 << 6);
        assertEq(bitmap, expected);
        assertTrue(BitmapLib.getBit(bitmap, 0));
        assertFalse(BitmapLib.getBit(bitmap, 2));
        assertTrue(BitmapLib.getBit(bitmap, 4));
        assertTrue(BitmapLib.getBit(bitmap, 6));
    }

    function testFuzz(uint256 bitmap, uint8 index, bool isTrue, uint8 otherIndex) public pure {
        vm.assume(index != otherIndex);

        bool otherBitIsSet = BitmapLib.getBit(bitmap, otherIndex);
        uint256 result = BitmapLib.withBit(bitmap, index, isTrue);
        bool bitIsSet = BitmapLib.getBit(result, index);
        bool otherBitIsStillSet = BitmapLib.getBit(result, otherIndex);

        assertEq(bitIsSet, isTrue);
        // Other bit should remain unchanged
        assertEq(otherBitIsStillSet, otherBitIsSet);
    }
}

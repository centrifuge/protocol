// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {BytesLib} from "src/libraries/BytesLib.sol";

contract BytesLibTest is Test {
    function testSlice(bytes memory data, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(data)), randomEnd);
        assertEq(BytesLib.slice(value, randomStart.length, data.length), data);
    }

    function testToAddress(address addr, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(addr)), randomEnd);
        assertEq(BytesLib.toAddress(value, randomStart.length), addr);
    }

    function testToUint8(uint8 number, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(number)), randomEnd);
        assertEq(BytesLib.toUint8(value, randomStart.length), number);
    }

    function testToUint16(uint16 number, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(number)), randomEnd);
        assertEq(BytesLib.toUint16(value, randomStart.length), number);
    }

    function testToUint64(uint64 number, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(number)), randomEnd);
        assertEq(BytesLib.toUint64(value, randomStart.length), number);
    }

    function testToUint128(uint128 number, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(number)), randomEnd);
        assertEq(BytesLib.toUint128(value, randomStart.length), number);
    }

    function testToBytes32(bytes32 data, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(data)), randomEnd);
        assertEq(BytesLib.toBytes32(value, randomStart.length), data);
    }

    function testToBytes16(bytes16 data, bytes memory randomStart, bytes memory randomEnd) public {
        bytes memory value = bytes.concat(bytes.concat(randomStart, abi.encodePacked(data)), randomEnd);
        assertEq(BytesLib.toBytes16(value, randomStart.length), data);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

contract TransientStorageLibTest is Test {
    function testAddress(bytes32 key, address value) public {
        assertEq(TransientStorageLib.tloadAddress(key), address(0));
        TransientStorageLib.tstore(key, value);
        assertEq(TransientStorageLib.tloadAddress(key), value);
    }

    function testUint128(bytes32 key, uint128 value) public {
        assertEq(TransientStorageLib.tloadUint128(key), uint128(0));
        TransientStorageLib.tstore(key, value);
        assertEq(TransientStorageLib.tloadUint128(key), value);
    }

    function testUint256(bytes32 key, uint256 value) public {
        assertEq(TransientStorageLib.tloadUint256(key), uint256(0));
        TransientStorageLib.tstore(key, value);
        assertEq(TransientStorageLib.tloadUint256(key), value);
    }

    function testBytes32(bytes32 key, bytes32 value) public {
        assertEq(TransientStorageLib.tloadBytes32(key), bytes32(""));
        TransientStorageLib.tstore(key, value);
        assertEq(TransientStorageLib.tloadBytes32(key), value);
    }

    function testBool(bytes32 key, bool value) public {
        assertEq(TransientStorageLib.tloadBool(key), false);
        TransientStorageLib.tstore(key, value);
        assertEq(TransientStorageLib.tloadBool(key), value);
    }
}

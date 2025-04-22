// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {TransientBytesLib} from "src/misc/libraries/TransientBytesLib.sol";

contract TransientBytesLibTest is Test {
    function testTransientBytes(bytes calldata data1, bytes calldata data2, bytes32 invalidKey) public {
        bytes32 key = keccak256(abi.encode("key"));
        vm.assume(key != invalidKey);

        TransientBytesLib.set(key, data1);
        assertEq(TransientBytesLib.get(key), data1);

        TransientBytesLib.set(key, data2);
        assertEq(TransientBytesLib.get(key), data2);

        assertEq(TransientBytesLib.get(invalidKey).length, 0);
    }

    function testAppend(bytes calldata data1, bytes calldata data2) public {
        bytes32 key = keccak256(abi.encode("key"));

        TransientBytesLib.set(key, data1);
        assertEq(TransientBytesLib.get(key), data1);

        TransientBytesLib.append(key, data2);
        assertEq(TransientBytesLib.get(key), bytes.concat(data1, data2));
    }
}

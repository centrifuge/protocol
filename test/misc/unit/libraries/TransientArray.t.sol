// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {TransientArrayLib} from "src/misc/libraries/TransientArrayLib.sol";

contract TransientArrayLibTest is Test {
    function testTransientArray(bytes32 invalidKey) public {
        bytes32 key = keccak256(abi.encode("key"));
        vm.assume(key != invalidKey);

        assertEq(TransientArrayLib.length(key), 0);

        // Push 2 items
        TransientArrayLib.push(key, bytes32("1"));
        TransientArrayLib.push(key, bytes32("2"));

        assertEq(TransientArrayLib.length(key), 2);

        bytes32[] memory stored = TransientArrayLib.getBytes32(key);
        assertEq(stored.length, 2);
        assertEq(stored[0], bytes32("1"));
        assertEq(stored[1], bytes32("2"));

        // Push 1 more
        TransientArrayLib.push(key, bytes32("3"));

        assertEq(TransientArrayLib.length(key), 3);

        stored = TransientArrayLib.getBytes32(key);
        assertEq(stored.length, 3);
        assertEq(stored[0], bytes32("1"));
        assertEq(stored[1], bytes32("2"));
        assertEq(stored[2], bytes32("3"));

        // Clear
        TransientArrayLib.clear(key);

        assertEq(TransientArrayLib.length(key), 0);

        stored = TransientArrayLib.getBytes32(key);
        assertEq(stored.length, 0);

        assertEq(TransientArrayLib.length(invalidKey), 0);
    }
}

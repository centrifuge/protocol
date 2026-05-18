// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TransientArrayLib} from "../../../../src/misc/libraries/TransientArrayLib.sol";

import "forge-std/Test.sol";

contract TransientArrayHarness {
    function push(bytes32 key, bytes32 value) external {
        TransientArrayLib.push(key, value);
    }

    function at(bytes32 key, uint256 index) external view returns (bytes32) {
        return TransientArrayLib.at(key, index);
    }

    function length(bytes32 key) external view returns (uint256) {
        return TransientArrayLib.length(key);
    }
}

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

    function testAtOutOfBoundsReverts() public {
        TransientArrayHarness harness = new TransientArrayHarness();
        bytes32 key = keccak256(abi.encode("key"));

        vm.expectRevert(TransientArrayLib.IndexOutOfBounds.selector);
        harness.at(key, 0);
    }

    function testAtOutOfBoundsAfterPushReverts() public {
        TransientArrayHarness harness = new TransientArrayHarness();
        bytes32 key = keccak256(abi.encode("key"));
        harness.push(key, bytes32("1"));

        // Index 0 should work
        assertEq(harness.at(key, 0), bytes32("1"));

        // Index 1 should revert
        vm.expectRevert(TransientArrayLib.IndexOutOfBounds.selector);
        harness.at(key, 1);
    }
}

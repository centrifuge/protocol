// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {TransientBytesLib} from "src/misc/libraries/TransientBytesLib.sol";

contract TransientBytesLibTest is Test {
    function testTransientArray(bytes calldata data) public {
        bytes32 key = keccak256(abi.encode("key"));
        TransientBytesLib.set(key, data);

        assertEq(TransientBytesLib.get(key), data);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessagesLib} from "src/vaults/libraries/MessagesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/vaults/libraries/BytesLib.sol";
import "forge-std/Test.sol";

contract MessagesLibTest is Test {
    using CastLib for *;
    using BytesLib for bytes;

    function setUp() public {}

    function testMessageType() public pure {
        uint64 poolId = 1;
        bytes memory payload = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);

        assertTrue(MessagesLib.messageType(payload) == MessagesLib.Call.AddPool);
    }
}

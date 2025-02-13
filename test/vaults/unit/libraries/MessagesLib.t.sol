// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {MessagesLib} from "src/libraries/MessagesLib.sol";
import {CastLib} from "src/libraries/CastLib.sol";
import {BytesLib} from "src/libraries/BytesLib.sol";
import "forge-std/Test.sol";

contract MessagesLibTest is Test {
    using CastLib for *;
    using BytesLib for bytes;

    function setUp() public {}

    function testMessageType() public {
        uint64 poolId = 1;
        bytes memory payload = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);

        assertTrue(MessagesLib.messageType(payload) == MessagesLib.Call.AddPool);
    }
}

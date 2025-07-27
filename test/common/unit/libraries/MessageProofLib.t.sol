// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageProofLib} from "../../../../src/common/libraries/MessageProofLib.sol";

import "forge-std/Test.sol";

contract TestMessageProofLibIdentities is Test {
    using MessageProofLib for *;

    function testMessageProof(bytes32 hash_) public pure {
        assertEq(hash_, MessageProofLib.deserializeMessageProof(MessageProofLib.serializeMessageProof(hash_)));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testDeserializeMessageId(uint8 kind) public {
        bytes memory buffer = new bytes(1);
        buffer[0] = bytes1(uint8(kind));
        vm.assume(kind != MessageProofLib.MESSAGE_PROOF_ID);

        vm.expectRevert(MessageProofLib.UnknownMessageProofType.selector);
        MessageProofLib.deserializeMessageProof(buffer);
    }
}

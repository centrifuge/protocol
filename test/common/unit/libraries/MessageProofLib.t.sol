// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageProofLib} from "src/common/libraries/MessageProofLib.sol";

import "forge-std/Test.sol";

contract TestMessageProofLibIdentities is Test {
    using MessageProofLib for *;

    function testMessageProof(bytes32 hash_) public pure {
        assertEq(hash_, MessageProofLib.deserializeMessageProof(MessageProofLib.serializeMessageProof(hash_)));
    }
}

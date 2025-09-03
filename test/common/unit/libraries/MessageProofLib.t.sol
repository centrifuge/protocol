// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {MessageProofLib} from "../../../../src/common/libraries/MessageProofLib.sol";

import "forge-std/Test.sol";

contract TestMessageProofLibIdentities is Test {
    using MessageProofLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);

    function testIdentity(PoolId poolId, bytes32 hash_) public pure {
        bytes memory encoded = MessageProofLib.createMessageProof(poolId, hash_);
        assertEq(poolId.raw(), MessageProofLib.proofPoolId(encoded).raw());
        assertEq(hash_, MessageProofLib.proofHash(encoded));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testErrUnknownMessageProofType(uint8 kind) public {
        bytes memory buffer = new bytes(1);
        buffer[0] = bytes1(uint8(kind));
        vm.assume(kind != MessageProofLib.MESSAGE_PROOF_ID);

        vm.expectRevert(MessageProofLib.UnknownMessageProofType.selector);
        MessageProofLib.proofPoolId(buffer);

        vm.expectRevert(MessageProofLib.UnknownMessageProofType.selector);
        MessageProofLib.proofHash(buffer);
    }
}

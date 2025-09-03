// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {PoolId} from "../types/PoolId.sol";

library MessageProofLib {
    using BytesLib for bytes;

    uint8 constant MESSAGE_PROOF_ID = 255;

    error UnknownMessageProofType();

    function proofPoolId(bytes memory data) internal pure returns (PoolId) {
        require(data.toUint8(0) == MESSAGE_PROOF_ID, UnknownMessageProofType());
        return PoolId.wrap(data.toUint64(1));
    }

    function proofHash(bytes memory data) internal pure returns (bytes32) {
        require(data.toUint8(0) == MESSAGE_PROOF_ID, UnknownMessageProofType());
        return data.toBytes32(9);
    }

    function createMessageProof(PoolId poolId, bytes32 hash) internal pure returns (bytes memory) {
        return abi.encodePacked(MESSAGE_PROOF_ID, poolId, hash);
    }
}

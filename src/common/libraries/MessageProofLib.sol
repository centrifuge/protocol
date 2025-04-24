// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";

library MessageProofLib {
    using BytesLib for bytes;

    uint8 constant MESSAGE_PROOF_ID = 1;

    error UnknownMessageProofType();

    function deserializeMessageProof(bytes memory data) internal pure returns (bytes32) {
        require(data.toUint8(0) == MESSAGE_PROOF_ID, UnknownMessageProofType());
        return data.toBytes32(1);
    }

    function serializeMessageProof(bytes32 hash) internal pure returns (bytes memory) {
        return abi.encodePacked(MESSAGE_PROOF_ID, hash);
    }
}

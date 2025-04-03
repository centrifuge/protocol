// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/common/mocks/Mock.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MessageType} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";

contract MockGasService is Mock, IGasService {
    using BytesLib for bytes;

    function gasLimit(uint16, bytes calldata payload) public view returns (uint64) {
        uint8 call = payload.toUint8(0);
        if (call == uint8(MessageType.MessageProof)) {
            return uint64(values_uint256_return["proof_estimate"]);
        }
        return uint64(values_uint256_return["message_estimate"]);
    }
}

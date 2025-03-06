// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/mocks/Mock.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MessageType} from "src/common/libraries/MessageLib.sol";

contract MockGasService is Mock {
    using BytesLib for bytes;

    function estimate(uint32, bytes calldata payload) public view returns (uint256) {
        uint8 call = payload.toUint8(0);
        if (call == uint8(MessageType.MessageProof)) {
            return values_uint256_return["proof_estimate"];
        }
        return values_uint256_return["message_estimate"];
    }

    function shouldRefuel(address, bytes calldata) public returns (bool) {
        call("shouldRefuel");
        return values_bool_return["shouldRefuel"];
    }
}

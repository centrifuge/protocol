// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/common/mocks/Mock.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {MessageType} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";

contract MockGasService is Mock, IGasService {
    using BytesLib for bytes;

    function gasLimit(uint16, bytes calldata) public view returns (uint128) {
        return uint128(values_uint256_return["gasLimit"]);
    }

    function maxBatchSize(uint16) public view returns (uint128) {
        return uint128(values_uint256_return["maxBatchSize"]);
    }
}

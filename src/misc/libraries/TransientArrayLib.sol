// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

/// @title  TransientArrayLib
library TransientArrayLib {
    using TransientStorageLib for bytes32;

    function push(bytes32 key, bytes32 value) internal {
        bytes32 lengthSlot = keccak256(abi.encodePacked(key, type(uint256).max));
        uint256 length_ = lengthSlot.tloadUint256();
        lengthSlot.tstore(length_ + 1);

        bytes32 slot = keccak256(abi.encodePacked(key, length_));
        slot.tstore(value);
    }

    function getBytes32(bytes32 key) internal view returns (bytes32[] memory) {
        uint256 length_ = length(key);

        bytes32[] memory data = new bytes32[](length_);
        for (uint256 i = 0; i < length_; i++) {
            bytes32 slot = keccak256(abi.encodePacked(key, i));
            data[i] = slot.tloadBytes32();
        }

        return data;
    }

    function length(bytes32 key) internal view returns (uint256) {
        return keccak256(abi.encodePacked(key, type(uint256).max)).tloadUint256();
    }

    function clear(bytes32 key) internal {
        bytes32 lengthSlot = keccak256(abi.encodePacked(key, type(uint256).max));
        lengthSlot.tstore(uint256(0));
    }
}

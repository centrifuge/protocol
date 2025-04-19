// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

/// @title  TransientBytesLib
library TransientBytesLib {
    using TransientStorageLib for bytes32;
    using BytesLib for bytes;

    function set(bytes32 key, bytes memory value) internal {
        uint256 chunks = value.length / 32 + 1;

        bytes32 lengthSlot = keccak256(abi.encodePacked(key, type(uint256).max));
        lengthSlot.tstore(value.length);

        for (uint256 i = 0; i < chunks; i++) {
            bytes32 slot = keccak256(abi.encodePacked(key, i));
            slot.tstore(bytes32(value.sliceZeroPadded(i * 32, 32)));
        }
    }

    function get(bytes32 key) internal view returns (bytes memory) {
        bytes memory data;
        uint256 length = keccak256(abi.encodePacked(key, type(uint256).max)).tloadUint256();
        if (length == 0) return data;

        uint256 chunks = length / 32 + 1;
        for (uint256 i = 0; i < chunks; i++) {
            bytes32 slot = keccak256(abi.encodePacked(key, i));
            data = bytes.concat(data, slot.tloadBytes32());
        }

        return data.slice(0, length);
    }

    function clear(bytes32 key) internal {
        bytes32 lengthSlot = keccak256(abi.encodePacked(key, type(uint256).max));
        lengthSlot.tstore(uint256(0));
    }
}

// SPDX-License-Identifier: BUSL-1.1
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

    function append(bytes32 key, bytes memory value) internal {
        bytes32 lengthSlot = keccak256(abi.encodePacked(key, type(uint256).max));
        uint256 prevLength = lengthSlot.tloadUint256();

        uint256 startChunk = prevLength / 32;
        uint256 offset = prevLength % 32;

        lengthSlot.tstore(prevLength + value.length);
        uint256 chunks = (prevLength + value.length) / 32 + 1;

        bytes32 joinSlot = keccak256(abi.encodePacked(key, startChunk));
        bytes memory firstPart = abi.encodePacked(joinSlot.tloadBytes32()).sliceZeroPadded(0, offset);
        bytes memory secondPart = value.sliceZeroPadded(0, 32 - offset);
        joinSlot.tstore(bytes32(bytes.concat(firstPart, secondPart)));

        for (uint256 i = startChunk + 1; i < chunks; i++) {
            bytes32 slot = keccak256(abi.encodePacked(key, i));
            slot.tstore(bytes32(value.sliceZeroPadded((32 - offset) + i * 32, 32)));
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

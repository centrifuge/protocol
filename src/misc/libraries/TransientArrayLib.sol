// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {TransientStorageLib} from "./TransientStorageLib.sol";

/// @title  TransientArrayLib
library TransientArrayLib {
    using TransientStorageLib for bytes32;

    function push(bytes32 key, bytes32 value) internal {
        bytes32 lengthSlot = keccak256(abi.encodePacked(key));
        uint256 length_ = lengthSlot.tloadUint256();
        lengthSlot.tstore(length_ + 1);

        uint256 baseSlot = uint256(lengthSlot);
        bytes32 slot = bytes32(baseSlot + length_ + 1);
        slot.tstore(value);
    }

    function getBytes32(bytes32 key) internal view returns (bytes32[] memory) {
        uint256 length_ = length(key);

        bytes32[] memory data = new bytes32[](length_);
        uint256 baseSlot = uint256(keccak256(abi.encodePacked(key)));
        for (uint256 i = 0; i < length_; i++) {
            bytes32 slot = bytes32(baseSlot + i + 1);
            data[i] = slot.tloadBytes32();
        }

        return data;
    }

    function length(bytes32 key) internal view returns (uint256) {
        return keccak256(abi.encodePacked(key)).tloadUint256();
    }

    function clear(bytes32 key) internal {
        bytes32 lengthSlot = keccak256(abi.encodePacked(key));
        lengthSlot.tstore(uint256(0));
    }
}

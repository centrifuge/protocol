// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  TransientStorageLib
library TransientStorageLib {
    function tstore(bytes32 slot, address value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tstore(bytes32 slot, bytes32 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tstore(bytes32 slot, bool value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tloadAddress(bytes32 slot) internal view returns (address value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tloadUint128(bytes32 slot) internal view returns (uint128 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tloadUint256(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tloadBytes32(bytes32 slot) internal view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function tloadBool(bytes32 slot) internal view returns (bool value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}

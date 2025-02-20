// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  TransientStorage
library TransientStorage {
    function tstore(bytes32 slot, address value) internal {
        assembly {
            tstore(slot, value)
        }
    }

    function tstore(bytes32 slot, uint256 value) internal {
        assembly {
            tstore(slot, value)
        }
    }

    function tloadAddress(bytes32 slot) internal view returns (address value) {
        assembly {
            value := tload(slot)
        }
    }

    function tloadUint256(bytes32 slot) internal view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }
}

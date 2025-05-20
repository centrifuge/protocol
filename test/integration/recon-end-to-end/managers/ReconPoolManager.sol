// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "@recon/EnumerableSet.sol";

import {PoolId} from "src/common/types/PoolId.sol";

/// @dev Source of truth for the assets being used in the test
/// @notice No assets should be used in the suite without being added here first
abstract contract ReconPoolManager {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice The current target for this set of variables
    uint64 private __pool;

    /// @notice The list of all assets being used
    EnumerableSet.UintSet private _pools;

    // If the current target is address(0) then it has not been setup yet and should revert
    error PoolNotSetup();
    // Do not allow duplicates
    error PoolExists();
    // Enable only added assets
    error PoolNotAdded();

    /// @notice Returns the current active asset
    function _getPool() internal view returns (uint64) {
        return __pool;
    }

    /// @notice Returns all pools being used
    function _getPools() internal view returns (uint64[] memory) {
        uint256[] memory rawValues = _pools.values();
        uint64[] memory result = new uint64[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            result[i] = uint64(rawValues[i]);
        }
        return result;
    }

    /// @notice Adds a pool to the list of pools and sets it as the current pool
    /// @param target The id of the pool to add
    function _addPool(uint64 target) internal {
        if (_pools.contains(uint256(target))) {
            revert PoolExists();
        }

        _pools.add(uint256(target));
        __pool = target;
    }

    /// @notice Removes a pool from the list of pools
    /// @param target The id of the pool to remove
    function _removePool(uint64 target) internal {
        if (!_pools.contains(uint256(target))) {
            revert PoolNotAdded();
        }

        _pools.remove(uint256(target));
    }

    /// @notice Switches the current pool based on the entropy
    /// @param entropy The entropy to choose a random pool in the set for switching
    function _switchPool(uint256 entropy) internal {
        uint64 target = uint64(_pools.at(entropy % _pools.length()));
        __pool = target;
    }
}

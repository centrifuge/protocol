// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "@recon/EnumerableSet.sol";

import {PoolId} from "src/core/types/PoolId.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";

/// @dev Source of truth for the assets being used in the test
/// @notice No assets should be used in the suite without being added here first
abstract contract ReconPoolManager {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice The current target for this set of variables
    uint64 private __pool;

    /// @notice The list of all assets being used
    EnumerableSet.UintSet private _pools;
    
    /// @notice Mapping of pool to share classes
    mapping(PoolId => EnumerableSet.Bytes32Set) private _poolShareClasses;

    // If the current target is address(0) then it has not been setup yet and should revert
    error PoolNotSetup();
    // Do not allow duplicates
    error PoolExists();
    // Enable only added assets
    error PoolNotAdded();

    /// @notice Returns the current active asset
    function _getPool() internal view returns (PoolId) {
        return PoolId.wrap(__pool);
    }

    /// @notice Returns all pools being used
    function _getPools() internal view returns (PoolId[] memory) {
        uint256[] memory rawValues = _pools.values();
        PoolId[] memory result = new PoolId[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            result[i] = PoolId.wrap(uint64(rawValues[i]));
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
        uint256[] memory pools = _pools.values();
        uint64 target = uint64(pools[entropy % pools.length]);
        __pool = target;
    }

    /// @notice Adds a share class to a specific pool
    /// @param poolId The pool to add the share class to
    /// @param scId The share class ID to add
    function _addShareClassToPool(PoolId poolId, ShareClassId scId) internal {
        _poolShareClasses[poolId].add(bytes32(ShareClassId.unwrap(scId)));
    }

    /// @notice Removes a share class from a specific pool
    /// @param poolId The pool to remove the share class from
    /// @param scId The share class ID to remove
    function _removeShareClassFromPool(PoolId poolId, ShareClassId scId) internal {
        _poolShareClasses[poolId].remove(bytes32(ShareClassId.unwrap(scId)));
    }

    /// @notice Returns all share classes for a given pool
    /// @param poolId The pool to get share classes for
    /// @return Share class IDs for the pool
    function _getPoolShareClasses(PoolId poolId) internal view returns (ShareClassId[] memory) {
        bytes32[] memory rawValues = _poolShareClasses[poolId].values();
        ShareClassId[] memory result = new ShareClassId[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            result[i] = ShareClassId.wrap(bytes16(rawValues[i]));
        }
        return result;
    }

    /// @notice Checks if a share class exists for a pool
    /// @param poolId The pool to check
    /// @param scId The share class ID to check
    /// @return True if the share class exists for the pool
    function _poolHasShareClass(PoolId poolId, ShareClassId scId) internal view returns (bool) {
        return _poolShareClasses[poolId].contains(bytes32(ShareClassId.unwrap(scId)));
    }
}

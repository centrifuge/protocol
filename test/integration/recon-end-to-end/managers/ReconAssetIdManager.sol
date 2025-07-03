// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "@recon/EnumerableSet.sol";

import {AssetId} from "src/common/types/AssetId.sol";

/// @dev Source of truth for the assetIds being used in the test
/// @notice No assetIds should be used in the suite without being added here first
abstract contract ReconAssetIdManager {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice The current target for this set of variables
    uint128 private __assetId;

    /// @notice The list of all assetIds being used
    EnumerableSet.UintSet private _assetIds;

    // If the current target is 0 then it has not been setup yet and should revert
    error AssetIdNotSetup();
    // Do not allow duplicates
    error AssetIdExists();
    // Enable only added assetIds
    error AssetIdNotAdded();

    /// @notice Returns the current active assetId
    function _getAssetId() internal view returns (uint128) {
        return __assetId;
    }

    /// @notice Returns all assetIds being used
    function _getAssetIds() internal view returns (uint128[] memory) {
        uint256[] memory rawValues = _assetIds.values();
        uint128[] memory result = new uint128[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            result[i] = uint128(rawValues[i]);
        }
        return result;
    }

    /// @notice Adds an assetId to the list of assetIds and sets it as the current assetId
    /// @param target The id of the assetId to add
    function _addAssetId(uint128 target) internal {
        if (_assetIds.contains(uint256(target))) {
            revert AssetIdExists();
        }

        _assetIds.add(uint256(target));
        __assetId = target;
    }

    /// @notice Removes an assetId from the list of assetIds
    /// @param target The id of the assetId to remove
    function _removeAssetId(uint128 target) internal {
        if (!_assetIds.contains(uint256(target))) {
            revert AssetIdNotAdded();
        }

        _assetIds.remove(uint256(target));
    }

    /// @notice Switches the current assetId based on the entropy
    /// @param entropy The entropy to choose a random assetId in the set for switching
    function _switchAssetId(uint256 entropy) internal {
        uint128 target = uint128(_assetIds.at(entropy % _assetIds.length()));
        __assetId = target;
    }
}

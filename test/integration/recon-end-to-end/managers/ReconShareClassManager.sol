// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "@recon/EnumerableSet.sol";

import {PoolId} from "src/common/types/PoolId.sol";

/// @dev Source of truth for the share classes being used in the test
/// @notice No share classes should be used in the suite without being added here first
abstract contract ReconShareClassManager {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice The current target for this set of variables
    bytes16 private __shareClassId;

    /// @notice The list of all share classes being used
    EnumerableSet.Bytes32Set private _shareClassIds;

    // If the current target is address(0) then it has not been setup yet and should revert
    error ShareClassNotSetup();
    // Do not allow duplicates
    error ShareClassExists();
    // Enable only added share classes
    error ShareClassNotAdded();

    /// @notice Returns the current active share class
    function _getShareClassId() internal view returns (bytes16) {
        return __shareClassId;
    }

    /// @notice Returns all share classes being used
    function _getShareClassIds() internal view returns (bytes16[] memory) {
        bytes32[] memory rawValues = _shareClassIds.values();
        bytes16[] memory result = new bytes16[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            result[i] = bytes16(rawValues[i]);
        }
        return result;
    }

    /// @notice Adds a share class to the list of share classes and sets it as the current share class
    /// @param target The id of the share class to add
    function _addShareClassId(bytes16 target) internal {
        if (_shareClassIds.contains(bytes32(target))) {
            revert ShareClassExists();
        }

        _shareClassIds.add(bytes32(target));
        __shareClassId = target;
    }

    /// @notice Removes a share class from the list of share classes
    /// @param target The id of the share class to remove
    function _removeShareClassId(bytes16 target) internal {
        if (!_shareClassIds.contains(bytes32(target))) {
            revert ShareClassNotAdded();
        }

        _shareClassIds.remove(bytes32(target));
    }

    /// @notice Switches the current share class based on the entropy
    /// @param entropy The entropy to choose a random share class in the set for switching
    function _switchShareClassId(uint256 entropy) internal {
        bytes16 target = bytes16(_shareClassIds.at(entropy % _shareClassIds.length()));
        __shareClassId = target;
    }
}

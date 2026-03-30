// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

import {EnumerableSet} from "@recon/EnumerableSet.sol";

/// @title ReconShareClassManager - Share Class Tracking for Invariant Tests
/// @dev Source of truth for the share classes being used in the test
/// @notice No share classes should be used in the suite without being added here first
///
/// IMPORTANT INVARIANT MAINTAINED BY THIS CONTRACT:
/// ================================================
/// When using this manager in conjunction with ReconShareManager, the following invariant
/// should be maintained by derived contracts:
///
///     _getShareToken() == spoke.shareToken(_getPool(), _getShareClassId())
///
/// This invariant ensures that ghost variables keyed by share token addresses remain
/// synchronized with the actual protocol state.
///
/// Design Philosophy: Auto-Update with Opt-Out
/// ========================================================
/// This contract uses a hook pattern (_onShareClassIdChanged) that allows derived contracts
/// to automatically sync related state when the share class changes. This:
///
/// 1. Maintains consistency by default - prevents ghost variable tracking bugs
/// 2. Honors semantic naming - _getShareToken() returns token for current (pool, shareClass)
/// 3. Preserves flexibility - explicit switch_share_token() can still break consistency for testing
///
/// See Setup.sol's _onShareClassIdChanged() override for the implementation that maintains
/// this invariant by calling _setShareToken() when share class changes.
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
    function _getShareClassId() internal view returns (ShareClassId) {
        return ShareClassId.wrap(__shareClassId);
    }

    /// @notice Returns all share classes being used
    function _getShareClassIds() internal view returns (ShareClassId[] memory) {
        bytes32[] memory rawValues = _shareClassIds.values();
        ShareClassId[] memory result = new ShareClassId[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            result[i] = ShareClassId.wrap(bytes16(rawValues[i]));
        }
        return result;
    }

    /// @notice Adds a share class to the list of share classes and sets it as the current share class
    /// @param target The id of the share class to add
    /// @dev After adding, calls _onShareClassIdChanged() hook for derived contracts to sync related state
    function _addShareClassId(bytes16 target) internal {
        if (_shareClassIds.contains(bytes32(target))) {
            revert ShareClassExists();
        }

        _shareClassIds.add(bytes32(target));
        __shareClassId = target;

        // Hook: Allow derived contracts to sync related state (e.g., update __shareToken)
        _onShareClassIdChanged(ShareClassId.wrap(target));
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
    /// @dev After switching, calls _onShareClassIdChanged() hook for derived contracts to sync related state
    function _switchShareClassId(uint256 entropy) internal {
        bytes32[] memory values = _shareClassIds.values();
        bytes16 target = bytes16(values[entropy % values.length]);
        __shareClassId = target;

        // Hook: Allow derived contracts to sync related state (e.g., update __shareToken)
        // This maintains the invariant: _getShareToken() == spoke.shareToken(_getPool(), _getShareClassId())
        _onShareClassIdChanged(ShareClassId.wrap(target));
    }

    /// @notice Hook called when share class changes - override in derived contracts to sync related state
    /// @param newShareClassId The new share class that was switched to
    /// @dev Default implementation does nothing. Override to maintain consistency with share tokens.
    function _onShareClassIdChanged(ShareClassId newShareClassId) internal virtual {}
}

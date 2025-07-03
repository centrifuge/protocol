// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "@recon/EnumerableSet.sol";

/// @dev Source of truth for the shareTokens being used in the test
/// @notice No shareTokens should be used in the suite without being added here first
abstract contract ReconShareManager {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The current target shareToken
    address private __shareToken;

    /// @notice The list of all shareTokens being used
    EnumerableSet.AddressSet private _shareTokens;

    // If the current target is address(0) then it has not been setup yet and should revert
    error ShareTokenNotSetup();
    // Do not allow duplicates
    error ShareTokenExists();
    // Enable only added shareTokens
    error ShareTokenNotAdded();

    /// @notice Returns the current active shareToken
    function _getShareToken() internal view returns (address) {
        return __shareToken;
    }

    /// @notice Returns all shareTokens being used
    function _getShareTokens() internal view returns (address[] memory) {
        return _shareTokens.values();
    }

    /// @notice Adds a shareToken to the list of shareTokens and sets it as the current shareToken
    /// @param shareToken The address of the shareToken to add
    function _addShareToken(address shareToken) internal {
        if (_shareTokens.contains(shareToken)) {
            revert ShareTokenExists();
        }

        _shareTokens.add(shareToken);
        __shareToken = shareToken; // sets the shareToken as the current shareToken
    }

    /// @notice Removes a shareToken from the list of shareTokens
    /// @param shareToken The address of the shareToken to remove
    function _removeShareToken(address shareToken) internal {
        if (!_shareTokens.contains(shareToken)) {
            revert ShareTokenNotAdded();
        }

        _shareTokens.remove(shareToken);
    }

    /// @notice Switches the current shareToken based on the entropy
    /// @param entropy The entropy to choose a random shareToken in the array for switching
    function _switchShareToken(uint256 entropy) internal {
        address shareToken = _shareTokens.at(entropy % _shareTokens.length());
        __shareToken = shareToken;
    }
}

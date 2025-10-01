// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "@recon/EnumerableSet.sol";
import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";

/// @dev Source of truth for the vaults being used in the test
/// @notice No vaults should be used in the suite without being added here first
abstract contract ReconVaultManager {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The current target vault
    address private __vault;

    /// @notice The list of all vaults being used
    EnumerableSet.AddressSet private _vaults;

    // If the current target is address(0) then it has not been setup yet and should revert
    error VaultNotSetup();
    // Do not allow duplicates
    error VaultExists();
    // Enable only added vaults
    error VaultNotAdded();

    /// @notice Returns the current active vault
    function _getVault() internal view returns (IBaseVault) {
        return IBaseVault(__vault);
    }

    /// @notice Returns all vaults being used
    function _getVaults() internal view returns (IBaseVault[] memory) {
        address[] memory vaultAddresses = _vaults.values();
        IBaseVault[] memory vaults = new IBaseVault[](vaultAddresses.length);
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            vaults[i] = IBaseVault(vaultAddresses[i]);
        }
        return vaults;
    }

    /// @notice Adds a vault to the list of vaults and sets it as the current vault
    /// @param vault The address of the vault to add
    function _addVault(address vault) internal {
        if (_vaults.contains(vault)) {
            revert VaultExists();
        }

        _vaults.add(vault);
        __vault = vault; // sets the vault as the current vault
    }

    /// @notice Removes a vault from the list of vaults
    /// @param vault The address of the vault to remove
    function _removeVault(address vault) internal {
        if (!_vaults.contains(vault)) {
            revert VaultNotAdded();
        }

        _vaults.remove(vault);
    }

    /// @notice Switches the current vault based on the entropy
    /// @param entropy The entropy to choose a random vault in the array for switching
    function _switchVault(uint256 entropy) internal {
        address[] memory vaults = _vaults.values();
        address vault = vaults[entropy % vaults.length];
        __vault = vault;
    }
}

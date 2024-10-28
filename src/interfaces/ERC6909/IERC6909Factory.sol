// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @dev  A factory contract to deploy new collateral contracts implementing IERC6909.
interface IERC6909Factory {
    /// @notice       Deploys new install of a contract that implements IERC6909.
    /// @dev          Factory should deploy deterministically if possible.
    ///
    /// @param owner  Owner of the deployed collateral contract which has initial full rights.
    /// @param salt   Used to make a deterministic deployment.
    /// @return       An address of the newly deployed contract.
    function deploy(address owner, bytes32 salt) external returns (address);

    /// @notice       Generates a new deterministic address based on the owner and the salt.
    ///
    /// @param owner  Owner of the deployed collateral contract which has initial full rights.
    /// @param salt   Used to make a deterministic deployment.
    /// @return       An address of the newly deployed contract.
    function previewAddress(address owner, bytes32 salt) external returns (address);
}

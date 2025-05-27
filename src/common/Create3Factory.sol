// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title Create3Factory
/// @notice Interface for the official CreateX factory deployed by pcaversaccio
/// @dev Using the official factory deployed at 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
interface Create3Factory {
    /// @notice Deploys a contract using CREATE3
    /// @param salt The salt for deterministic deployment
    /// @param creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function deploy(
        bytes32 salt,
        bytes memory creationCode
    ) external returns (address deployed);

    /// @notice Predicts the address of a contract deployed using CREATE3
    /// @param deployer The address of the deployer
    /// @param salt The salt for deterministic deployment
    /// @return deployed The address where the contract would be deployed
    function getDeployed(
        address deployer,
        bytes32 salt
    ) external view returns (address deployed);
}

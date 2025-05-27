// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title ICreateX
/// @notice Interface for the official CreateX factory deployed by pcaversaccio
/// @dev Using the official factory deployed at 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
interface ICreateX {
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

    /// @notice Computes the address of a contract that would be deployed using CREATE3
    /// @param salt The salt for deterministic deployment
    /// @return deployed The address where the contract would be deployed
    function computeCreate3Address(bytes32 salt) external view returns (address deployed);

    /// @notice Computes the address of a contract that would be deployed using CREATE3
    /// @param salt The salt for deterministic deployment
    /// @param deployer The address of the deployer
    /// @return deployed The address where the contract would be deployed
    function computeCreate3Address(bytes32 salt, address deployer) external view returns (address deployed);

    /// @notice Deploys a contract using CREATE3
    /// @param creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function deployCreate3(bytes memory creationCode) external returns (address deployed);

    /// @notice Deploys a contract using CREATE3
    /// @param salt The salt for deterministic deployment
    /// @param creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function deployCreate3(bytes32 salt, bytes memory creationCode) external returns (address deployed);

    /// @notice Deploys a contract using CREATE3 and initializes it
    /// @param creationCode The creation code of the contract to deploy
    /// @param initCode The initialization code
    /// @param value The value to send with the deployment
    /// @return deployed The address of the deployed contract
    function deployCreate3AndInit(
        bytes memory creationCode,
        bytes memory initCode,
        (uint256, uint256) memory value
    ) external returns (address deployed);

    /// @notice Deploys a contract using CREATE3 and initializes it
    /// @param salt The salt for deterministic deployment
    /// @param creationCode The creation code of the contract to deploy
    /// @param initCode The initialization code
    /// @param value The value to send with the deployment
    /// @return deployed The address of the deployed contract
    function deployCreate3AndInit(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory initCode,
        (uint256, uint256) memory value
    ) external returns (address deployed);

    /// @notice Deploys a contract using CREATE3 and initializes it
    /// @param creationCode The creation code of the contract to deploy
    /// @param initCode The initialization code
    /// @param value The value to send with the deployment
    /// @param refundAddress The address to refund excess value to
    /// @return deployed The address of the deployed contract
    function deployCreate3AndInit(
        bytes memory creationCode,
        bytes memory initCode,
        (uint256, uint256) memory value,
        address refundAddress
    ) external returns (address deployed);

    /// @notice Deploys a contract using CREATE3 and initializes it
    /// @param salt The salt for deterministic deployment
    /// @param creationCode The creation code of the contract to deploy
    /// @param initCode The initialization code
    /// @param value The value to send with the deployment
    /// @param refundAddress The address to refund excess value to
    /// @return deployed The address of the deployed contract
    function deployCreate3AndInit(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory initCode,
        (uint256, uint256) memory value,
        address refundAddress
    ) external returns (address deployed);
} 
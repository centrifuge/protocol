// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ITrancheFactory {
    /// @notice Used to deploy new tranche tokens.
    /// @dev    In order to have the same address on different EVMs `salt` should be used
    ///         during creationg process.
    /// @param name Name of the new token.
    /// @param symbol Symbol of the new token.
    /// @param decimals Decimals of the new token.
    /// @param salt Salt used for deterministic deployments.
    /// @param trancheWards Address which can call methods behind authorized only.
    function newTranche(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address[] calldata trancheWards
    ) external returns (address);

    /// @notice Returns the predicted address (using CREATE2)
    function getAddress(uint8 decimals, bytes32 salt) external view returns (address);
}

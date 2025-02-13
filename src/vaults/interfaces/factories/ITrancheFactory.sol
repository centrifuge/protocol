// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

interface ITrancheFactory {
    /// @notice Used to deploy new tranche tokens.
    /// @dev    In order to have the same address on different EVMs `salt` should be used
    ///         during creationg process.
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param trancheId Id of the tranche. Id is one of the already supported tranches.
    /// @param name Name of the new token.
    /// @param symbol Symbol of the new token.
    /// @param decimals Decimals of the new token.
    /// @param trancheWards Address which can call methods behind authorized only.
    function newTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        address[] calldata trancheWards
    ) external returns (address);

    /// @notice Returns the predicted address (using CREATE2)
    function getAddress(uint64 poolId, bytes16 trancheId, uint8 decimals) external view returns (address);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

interface ITokenFactory {
    /// @notice Used to deploy new share class tokens.
    /// @dev    In order to have the same address on different EVMs `salt` should be used
    ///         during creationg process.
    /// @param name Name of the new token.
    /// @param symbol Symbol of the new token.
    /// @param decimals Decimals of the new token.
    /// @param salt Salt used for deterministic deployments.
    /// @param tokenWards Address which can call methods behind authorized only.
    function newToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address[] calldata tokenWards
    ) external returns (IShareToken);

    /// @notice Returns the predicted address (using CREATE2)
    function getAddress(uint8 decimals, bytes32 salt) external view returns (address);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "../../interfaces/IShareToken.sol";

interface ITokenFactory {
    event File(bytes32 what, address[] addr);

    error FileUnrecognizedParam();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    function file(bytes32 what, address[] memory data) external;

    /// @notice Used to deploy new share class tokens.
    /// @dev    In order to have the same address on different EVMs `salt` should be used
    ///         during creation process.
    /// @param name Name of the new token.
    /// @param symbol Symbol of the new token.
    /// @param decimals Decimals of the new token.
    /// @param salt Salt used for deterministic deployments.
    function newToken(string memory name, string memory symbol, uint8 decimals, bytes32 salt)
        external
        returns (IShareToken);

    /// @notice Returns the predicted address (using CREATE2)
    function getAddress(uint8 decimals, bytes32 salt) external view returns (address);
}

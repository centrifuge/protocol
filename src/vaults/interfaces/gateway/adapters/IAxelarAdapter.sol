// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "src/vaults/interfaces/gateway/IAdapter.sol";

interface IAxelarGateway {
    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        external;

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool);
}

interface IAxelarGasService {
    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable;
}

interface IAxelarAdapter is IAdapter {
    event File(bytes32 indexed what, uint256 value);

    /// @dev This value is in Axelar fees in ETH (wei)
    function axelarCost() external view returns (uint256);

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'axelarCost'
    function file(bytes32 what, uint256 value) external;

    // --- Incoming ---
    /// @notice Execute a message
    /// @dev    Relies on Axelar to ensure messages cannot be executed more than once.
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}

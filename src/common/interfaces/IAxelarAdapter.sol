// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

// From https://github.com/axelarnetwork/axelar-cgp-solidity/blob/main/contracts/interfaces/IAxelarGateway.sol
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
    // From
    // https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/00682b6c3db0cc922ec0c4ea3791852c93d7ae31/contracts/gas-estimation/InterchainGasEstimation.sol#L48
    function estimateGasFee(
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        uint256 executionGasLimit,
        bytes calldata params
    ) external view returns (uint256 gasEstimate);

    // From https://github.com/axelarnetwork/axelar-cgp-solidity/blob/main/contracts/interfaces/IAxelarGasService.sol
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

    error FileUnrecognizedParam();
    error NotApprovedByAxelarGateway();
    error InvalidChain();
    error InvalidAddress();

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

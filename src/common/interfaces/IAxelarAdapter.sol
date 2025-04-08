// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

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

// From
// https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/00682b6c3db0cc922ec0c4ea3791852c93d7ae31/contracts/interfaces/IAxelarExecutable.sol#L14
interface IAxelarExecutable {
    /**
     * @dev Thrown when a function is called with an invalid address.
     */
    error InvalidAddress();

    /**
     * @dev Thrown when the call is not approved by the Axelar Gateway.
     */
    error NotApprovedByGateway();

    /**
     * @notice Executes the specified command sent from another chain.
     * @dev This function is called by the Axelar Gateway to carry out cross-chain commands.
     * Reverts if the call is not approved by the gateway or other checks fail.
     * @param commandId The identifier of the command to execute.
     * @param sourceChain The name of the source chain from where the command originated.
     * @param sourceAddress The address on the source chain that sent the command.
     * @param payload The payload of the command to be executed. This typically includes the function selector and
     * encoded arguments.
     */
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}

struct AxelarSource {
    uint16 centrifugeId;
    address addr;
}

struct AxelarDestination {
    string axelarId;
    address addr;
}

interface IAxelarAdapter is IAdapter, IAxelarExecutable {
    event File(bytes32 indexed what, string axelarId, uint16 centrifugeId, address source);
    event File(bytes32 indexed what, uint16 centrifugeId, string axelarId, address destination);

    error FileUnrecognizedParam();

    function file(bytes32 what, string calldata axelarId, uint16 centrifugeId, address source) external;
    function file(bytes32 what, uint16 centrifugeId, string calldata axelarId, address destination) external;
}

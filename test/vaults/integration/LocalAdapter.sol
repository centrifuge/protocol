// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

interface PrecompileLike {
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}

/// @title  Local Adapter
/// @notice Routing contract that routes from Substrate to EVM and back.
///         I.e. for testing LP in a local Centrifuge Chain deployment.
contract LocalAdapter is Auth, IAdapter {
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000800;
    bytes32 internal constant FAKE_COMMAND_ID = keccak256("FAKE_COMMAND_ID");

    IMessageHandler public gateway;
    string public sourceChain;
    string public sourceAddress;

    // --- Events ---
    event RouteToDomain(string destinationChain, string destinationContractAddress, bytes payload);
    event RouteToCentrifuge(bytes32 commandId, string sourceChain, string sourceAddress, bytes payload);
    event NativeGasPaidForContractCall(
        address sender,
        string destinationChain,
        string destinationAddress,
        bytes32 payload,
        uint256 gas,
        address refundAddress
    );
    event File(bytes32 indexed what, address addr);
    event File(bytes32 indexed what, string data);

    constructor() Auth(msg.sender) {}

    // --- Administrative ---
    function file(bytes32 what, address data) external {
        if (what == "gateway") {
            gateway = IMessageHandler(data);
        } else {
            revert("LocalAdapter/file-unrecognized-param");
        }

        emit File(what, data);
    }

    function file(bytes32 what, string calldata data) external {
        if (what == "sourceChain") {
            sourceChain = data;
        } else if (what == "sourceAddress") {
            sourceAddress = data;
        } else {
            revert("LocalAdapter/file-unrecognized-param");
        }

        emit File(what, data);
    }

    // --- Incoming ---
    // From Centrifuge to LP on Centrifuge (faking other domain)
    function callContract(
        string calldata destinationChain,
        string calldata destinationContractAddress,
        bytes calldata payload
    ) public {
        // TODO: get chainId
        gateway.handle(1, payload);
        emit RouteToDomain(destinationChain, destinationContractAddress, payload);
    }

    // --- Outgoing ---
    /// @inheritdoc IAdapter
    /// @dev From LP on Centrifuge (faking other domain) to Centrifuge
    function send(uint32, bytes calldata message, uint256, address) public payable {
        PrecompileLike precompile = PrecompileLike(PRECOMPILE);
        precompile.execute(FAKE_COMMAND_ID, sourceChain, sourceAddress, message);

        emit RouteToCentrifuge(FAKE_COMMAND_ID, sourceChain, sourceAddress, message);
    }

    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable {
        require(msg.value != 0, "Nothing Paid");

        emit NativeGasPaidForContractCall(
            sender, destinationChain, destinationAddress, keccak256(payload), msg.value, refundAddress
        );
    }

    /// @inheritdoc IAdapter
    function estimate(uint32, bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }

    // Added to be ignored in coverage report
    function test() public {}
}

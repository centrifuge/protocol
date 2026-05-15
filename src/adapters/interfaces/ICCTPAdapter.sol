// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../../admin/interfaces/IAdapterWiring.sol";

// From
// https://github.com/circlefin/evm-cctp-contracts/blob/master/src/interfaces/v2/IMessageTransmitterV2.sol

interface IMessageTransmitterV2 {
    /// @notice Send a generic message to the destination domain.
    /// @param destinationDomain The CCTP domain of the destination chain
    /// @param recipient The recipient address on the destination chain (left-padded bytes32)
    /// @param destinationCaller The only caller authorized to submit the attestation on the destination
    ///                          (bytes32(0) makes it permissionless)
    /// @param minFinalityThreshold The minimum finality at which the attestation may be issued
    ///                             (e.g. 1000 = finalized in CCTP V2)
    /// @param messageBody The message body to deliver
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external;

    /// @notice Receive a message previously emitted on a source chain, verified by a Circle attestation.
    /// @param message The raw CCTP message bytes
    /// @param attestation The Circle-signed attestation over `message`
    /// @return success True if the message was successfully relayed
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}

// From
// https://github.com/circlefin/evm-cctp-contracts/blob/master/src/interfaces/v2/IMessageHandlerV2.sol

interface IMessageHandlerV2 {
    /// @notice Called by the MessageTransmitter to deliver a finalized message.
    /// @param sourceDomain The CCTP domain of the source chain
    /// @param sender The sender on the source chain (left-padded bytes32)
    /// @param finalityThresholdExecuted The finality threshold at which this message was attested
    /// @param messageBody The message body
    /// @return success Must return true for the transmitter to mark the nonce as consumed
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool success);

    /// @notice Called by the MessageTransmitter to deliver an unfinalized (fast / instant) message.
    function handleReceiveUnfinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool success);
}

struct CCTPSource {
    uint16 centrifugeId;
    address addr;
}

struct CCTPDestination {
    uint32 cctpDomain;
    address addr;
}

/// @title  ICCTPAdapter
/// @notice Cross-chain messaging adapter for Circle's Cross-Chain Transfer Protocol (CCTP V2)
/// @dev    Bridges messages between Centrifuge chains using CCTP V2's generic messaging
///         (the `MessageTransmitter.sendMessage` / `receiveMessage` pair, independent of USDC).
///         Outbound messages have no on-chain fee. Circle's off-chain attestation service signs
///         the message and an off-chain relayer submits `receiveMessage` on the destination chain.
interface ICCTPAdapter is IAdapter, IAdapterWiring, IMessageHandlerV2 {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Wire(uint16 indexed centrifugeId, uint32 indexed cctpDomain, address adapter);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotMessageTransmitter();
    error InvalidSource();
    error UnfinalizedNotSupported();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice The MultiAdapter that receives decoded inbound messages from this adapter
    function entrypoint() external view returns (IMessageHandler);

    /// @notice The Circle CCTP V2 MessageTransmitter used to dispatch and receive messages
    function messageTransmitter() external view returns (IMessageTransmitterV2);

    /// @notice Returns the source configuration for a given CCTP domain ID
    /// @param cctpDomain The remote CCTP domain ID
    /// @return centrifugeId The remote Centrifuge chain id
    /// @return addr The address of the remote CCTP adapter
    function sources(uint32 cctpDomain) external view returns (uint16 centrifugeId, address addr);

    /// @notice Returns the destination configuration for a given Centrifuge chain ID
    /// @param centrifugeId The remote Centrifuge chain id
    /// @return cctpDomain The remote CCTP domain ID
    /// @return addr The address of the remote CCTP adapter
    function destinations(uint16 centrifugeId) external view returns (uint32 cctpDomain, address addr);
}

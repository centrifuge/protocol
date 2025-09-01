// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "../IAdapter.sol";

// From
// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol#L28C1-L34C1

/// @notice The message is the raw, original content or instruction as defined by the application in bytes. It
///         represents the core data that the sender intends to deliver to the recipient via the LayerZero Endpoint.
struct MessagingParams {
    uint32 dstEid; // destination chain endpoint id
    bytes32 receiver; // receiver on destination chain
    bytes message; // cross-chain message
    bytes options; // settings for executor and dvn
    bool payInLzToken; // whether to pay in ZRO token
}

struct MessagingReceipt {
    bytes32 guid; // unique identifier for the message
    uint64 nonce; // message nonce
    MessagingFee fee; // the message fee paid
}

struct MessagingFee {
    uint256 nativeFee; // fee in native token
    uint256 lzTokenFee; // fee in ZRO token
}

struct Origin {
    uint32 srcEid; // source chain endpoint id
    bytes32 sender; // sender on source chain
    uint64 nonce; // message nonce
}

interface ILayerZeroEndpointV2 {
    /// @notice This view function gives the application built on top of LayerZero the ability to requests a quote
    ///         with the same parameters as they would to send their message. Since the quotes are given on chain there
    ///         is a race condition in which the prices could change between the time the user gets their quote and the
    ///         time they submit their message. If the price moves up and the user doesn't send enough funds the
    ///         transaction will revert, if the price goes down the _refundAddress provided by the app will be refunded
    ///         the difference.
    function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory);

    /// @notice Send a LayerZero message to the specified address at a LayerZero endpoint specified by our chainId.
    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory);

    /// @notice Delegate is authorized by the oapp to configure anything in layerzero
    function setDelegate(address _delegate) external;
}

// From
// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroReceiver.sol

interface ILayerZeroReceiver {
    /// @notice Checks if the path initialization is allowed based on the provided origin.
    function allowInitializePath(Origin calldata _origin) external view returns (bool);

    /// @notice The path nonce starts from 1.
    ///         If 0 is returned it means that there is NO nonce ordered enforcement.
    ///         This function is required by the off-chain executor to determine
    ///         the OApp expects msg execution is ordered.
    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64);

    /// @notice Execute a verified message to the designated receiver
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

struct LayerZeroSource {
    uint16 centrifugeId;
    address addr;
}

struct LayerZeroDestination {
    uint32 layerZeroEid;
    address addr;
}

interface ILayerZeroAdapter is IAdapter, ILayerZeroReceiver {
    event File(bytes32 indexed what, uint32 indexed layerZeroEid, uint16 indexed centrifugeId, address addr);
    event File(bytes32 indexed what, uint16 indexed centrifugeId, uint32 indexed layerZeroEid, address addr);
    event SetDelegate(address indexed newDelegate);

    error NotLayerZeroEndpoint();
    error InvalidSource();
    error FileUnrecognizedParam();

    /// @notice Configure source mapping (incoming messages)
    /// @param what Must be "sources"
    /// @param layerZeroEid The source LayerZero Endpoint ID
    /// @param centrifugeId The source Centrifuge chain ID
    /// @param source The source LayerZero adapter address
    function file(bytes32 what, uint32 layerZeroEid, uint16 centrifugeId, address source) external;

    /// @notice Configure destination mapping (outgoing messages)
    /// @param what Must be "destinations"
    /// @param centrifugeId The destination Centrifuge chain ID
    /// @param layerZeroEid The destination LayerZero Endpoint ID
    /// @param destination The destination LayerZero adapter address
    function file(bytes32 what, uint16 centrifugeId, uint32 layerZeroEid, address destination) external;

    /// @notice Update the LayerZero delegate
    /// @param newDelegate The new delegate address for DVN configuration
    function setDelegate(address newDelegate) external;

    /// @notice Returns the source configuration for a given layerzero endpoint id
    /// @param layerZeroEid The remote LayerZero Endpoint ID
    /// @return centrifugeId The remote chain id
    /// @return addr The address of the remote layerzero adapter
    function sources(uint32 layerZeroEid) external view returns (uint16 centrifugeId, address addr);

    /// @notice Returns the destination configuration for a given chain id
    /// @param centrifugeId The remote chain id
    /// @return layerZeroEid The remote LayerZero Endpoint ID
    /// @return addr The address of the remote layerzero adapter
    function destinations(uint16 centrifugeId) external view returns (uint32 layerZeroEid, address addr);
}

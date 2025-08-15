// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "../../common/interfaces/IAdapter.sol";

// From
// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol#L28C1-L34C1
struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

interface ILayerZeroEndpointV2 {
    function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory);

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory);
}

// From
// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroReceiver.sol
interface ILayerZeroReceiver {
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
    uint32 layerZeroId;
    address addr;
}

interface ILayerZeroAdapter is IAdapter, ILayerZeroReceiver {
    error NotLayerZeroEndpoint();
    error InvalidSource();

    /// @notice Wire the adapter to a remote one.
    /// @param centrifugeId The remote chain's chain ID
    /// @param layerZeroId The remote chain's LayerZero ID
    /// @param adapter The remote chain's LayerZero adapter address
    function wire(uint16 centrifugeId, uint32 layerZeroId, address adapter) external;

    /// @notice Returns the source configuration for a given layerzero endpoint id
    /// @param layerZeroId The remote layerzero id
    /// @return centrifugeId The remote chain id
    /// @return addr The address of the remote layerzero adapter
    function sources(uint32 layerZeroId) external view returns (uint16 centrifugeId, address addr);

    /// @notice Returns the destination configuration for a given chain id
    /// @param centrifugeId The remote chain id
    /// @return layerZeroId The remote layerzero id
    /// @return addr The address of the remote layerzero adapter
    function destinations(uint16 centrifugeId) external view returns (uint32 layerZeroId, address addr);
}

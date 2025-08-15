// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    ILayerZeroAdapter,
    IAdapter,
    ILayerZeroReceiver,
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin,
    LayerZeroSource,
    LayerZeroDestination
} from "./interfaces/ILayerZeroAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {IMessageHandler} from "../common/interfaces/IMessageHandler.sol";

/// @title  LayerZero Adapter
/// @notice Routing contract that integrates with the LayerZero Relayer service
contract LayerZeroAdapter is Auth, ILayerZeroAdapter {
    using CastLib for *;

    IMessageHandler public immutable entrypoint;
    ILayerZeroEndpointV2 public immutable endpoint;

    mapping(uint32 layerZeroId => LayerZeroSource) public sources;
    mapping(uint16 centrifugeId => LayerZeroDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address endpoint_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        endpoint = ILayerZeroEndpointV2(endpoint_);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILayerZeroAdapter
    function wire(uint16 centrifugeId, uint32 layerZeroId, address adapter) external auth {
        sources[layerZeroId] = LayerZeroSource(centrifugeId, adapter);
        destinations[centrifugeId] = LayerZeroDestination(layerZeroId, adapter);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILayerZeroReceiver
    function lzReceive(Origin calldata origin, bytes32, bytes calldata payload, address, bytes calldata)
        external
        payable
    {
        LayerZeroSource memory source = sources[origin.srcEid];
        require(source.addr != address(0) && source.addr == origin.sender.toAddressLeftPadded(), InvalidSource());
        require(msg.sender == address(endpoint), NotLayerZeroEndpoint());

        entrypoint.handle(source.centrifugeId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256, address refund)
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        LayerZeroDestination memory destination = destinations[centrifugeId];
        require(destination.layerZeroId != 0, UnknownChainId());

        // TODO: encode gasLimit and DVNs into options
        MessagingParams memory params =
            MessagingParams(destination.layerZeroId, destination.addr.toBytes32LeftPadded(), payload, bytes(""), false);

        MessagingReceipt memory receipt = endpoint.send{value: msg.value}(params, refund);

        adapterData = receipt.guid;
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256) external view returns (uint256) {
        LayerZeroDestination memory destination = destinations[centrifugeId];

        // TODO: encode gasLimit and DVNs into options
        MessagingParams memory params =
            MessagingParams(destination.layerZeroId, destination.addr.toBytes32LeftPadded(), payload, bytes(""), false);

        MessagingFee memory fee = endpoint.quote(params, address(this));
        return fee.nativeFee;
    }
}

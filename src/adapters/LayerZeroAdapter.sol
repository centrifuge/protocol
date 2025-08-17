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
import {MathLib} from "../misc/libraries/MathLib.sol";

import {IMessageHandler} from "../common/interfaces/IMessageHandler.sol";

/// @title  LayerZero Adapter
/// @notice Routing contract that integrates with LayerZero V2.
/// @dev    A delegate should be set, to configure the DVN and executor
///         settings as well as the send/receive libraries.
///
///         Message ordering is not enforced.
contract LayerZeroAdapter is Auth, ILayerZeroAdapter {
    using CastLib for *;
    using MathLib for *;

    IMessageHandler public immutable entrypoint;
    ILayerZeroEndpointV2 public immutable endpoint;

    mapping(uint32 layerZeroEid => LayerZeroSource) public sources;
    mapping(uint16 centrifugeId => LayerZeroDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address endpoint_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        endpoint = ILayerZeroEndpointV2(endpoint_);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILayerZeroAdapter
    function wire(uint16 centrifugeId, uint32 layerZeroEid, address adapter) external auth {
        sources[layerZeroEid] = LayerZeroSource(centrifugeId, adapter);
        destinations[centrifugeId] = LayerZeroDestination(layerZeroEid, adapter);
        emit Wire(centrifugeId, layerZeroEid, adapter);
    }

    /// @dev Update the LayerZero delegate.
    function setDelegate(address newDelegate) external auth {
        endpoint.setDelegate(newDelegate);
        emit SetDelegate(newDelegate);
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

    /// @inheritdoc ILayerZeroReceiver
    function allowInitializePath(Origin calldata origin) external view override returns (bool) {
        LayerZeroSource memory source = sources[origin.srcEid];
        return source.addr != address(0) && source.addr == origin.sender.toAddressLeftPadded();
    }

    /// @inheritdoc ILayerZeroReceiver
    function nextNonce(uint32, bytes32) external pure override returns (uint64 nonce) {
        return 0;
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        LayerZeroDestination memory destination = destinations[centrifugeId];
        require(destination.layerZeroEid != 0, UnknownChainId());

        MessagingReceipt memory receipt =
            endpoint.send{value: msg.value}(_params(destination, payload, gasLimit), refund);
        adapterData = receipt.guid;
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        LayerZeroDestination memory destination = destinations[centrifugeId];
        MessagingFee memory fee = endpoint.quote(_params(destination, payload, gasLimit), address(this));
        return fee.nativeFee;
    }

    /// @dev Generate message parameters
    function _params(LayerZeroDestination memory destination, bytes calldata payload, uint256 gasLimit)
        internal
        pure
        returns (MessagingParams memory)
    {
        return MessagingParams(
            destination.layerZeroEid,
            destination.addr.toBytes32LeftPadded(),
            payload,
            _options(gasLimit.toUint128()),
            false
        );
    }

    //----------------------------------------------------------------------------------------------
    // Options builder
    //----------------------------------------------------------------------------------------------

    uint16 internal constant TYPE_3 = 3;
    uint8 internal constant WORKER_ID = 1;
    uint8 internal constant OPTION_TYPE_LZRECEIVE = 1;

    // Based on
    // https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/oapp/contracts/oapp/libs/OptionsBuilder.sol#L42
    function _options(uint128 gasLimit) internal pure returns (bytes memory) {
        bytes memory option = abi.encodePacked(gasLimit);
        return abi.encodePacked(
            TYPE_3,
            WORKER_ID,
            option.length.toUint16() + 1, // +1 for optionType
            OPTION_TYPE_LZRECEIVE,
            option
        );
    }
}

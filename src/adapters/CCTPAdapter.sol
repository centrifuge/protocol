// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    ICCTPAdapter,
    IAdapter,
    IMessageHandlerV2,
    IMessageTransmitterV2,
    CCTPSource,
    CCTPDestination
} from "./interfaces/ICCTPAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

/// @title  Circle CCTP Adapter
/// @notice Routing contract that integrates with the Circle CCTP V2 MessageTransmitter.
/// @dev    Replay protection is enforced by the MessageTransmitter, which tracks consumed
///         message nonces and reverts duplicate attestations.
contract CCTPAdapter is Auth, ICCTPAdapter {
    using CastLib for *;

    /// @dev CCTP V2 finalized finality threshold. Values < 1000 request fast (unfinalized) attestation.
    uint32 public constant MIN_FINALITY_THRESHOLD = 1000;

    IMessageTransmitterV2 public immutable messageTransmitter;
    IMessageHandler public immutable entrypoint;

    mapping(uint32 cctpDomain => CCTPSource) public sources;
    mapping(uint16 centrifugeId => CCTPDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address messageTransmitter_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        messageTransmitter = IMessageTransmitterV2(messageTransmitter_);
    }

    //----------------------------------------------------------------------------------------------
    // Network wiring
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterWiring
    function wire(uint16 centrifugeId, bytes memory data) external auth {
        (uint32 cctpDomain, address adapter) = abi.decode(data, (uint32, address));
        sources[cctpDomain] = CCTPSource(centrifugeId, adapter);
        destinations[centrifugeId] = CCTPDestination(cctpDomain, adapter);
        emit Wire(centrifugeId, cctpDomain, adapter);
    }

    /// @inheritdoc IAdapterWiring
    function isWired(uint16 centrifugeId) external view returns (bool) {
        return destinations[centrifugeId].addr != address(0);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandlerV2
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32, /* finalityThresholdExecuted */
        bytes calldata messageBody
    )
        external
        returns (bool)
    {
        require(msg.sender == address(messageTransmitter), NotMessageTransmitter());

        CCTPSource memory source = sources[sourceDomain];
        require(source.addr != address(0) && source.addr == sender.toAddressLeftPadded(), InvalidSource());

        entrypoint.handle(source.centrifugeId, messageBody);
        return true;
    }

    /// @inheritdoc IMessageHandlerV2
    /// @dev Unfinalized (fast) delivery is not accepted. Centrifuge messaging requires finalized state.
    function handleReceiveUnfinalizedMessage(uint32, bytes32, uint32, bytes calldata)
        external
        view
        returns (bool)
    {
        require(msg.sender == address(messageTransmitter), NotMessageTransmitter());
        revert UnfinalizedNotSupported();
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(
        uint16 centrifugeId,
        bytes calldata payload,
        uint256,
        /* gasLimit */
        address /* refund */
    )
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        CCTPDestination memory destination = destinations[centrifugeId];
        require(destination.addr != address(0), UnknownChainId());

        messageTransmitter.sendMessage(
            destination.cctpDomain, destination.addr.toBytes32LeftPadded(), bytes32(0), MIN_FINALITY_THRESHOLD, payload
        );
        return bytes32(0);
    }

    /// @inheritdoc IAdapter
    /// @dev CCTP messaging has no on-chain fee. Returns 0.
    function estimate(
        uint16 centrifugeId,
        bytes calldata,
        /* payload */
        uint256 /* gasLimit */
    )
        external
        view
        returns (uint256)
    {
        require(destinations[centrifugeId].addr != address(0), UnknownChainId());
        return 0;
    }
}

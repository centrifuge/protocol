// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IHyperlaneAdapter,
    IAdapter,
    IMessageRecipient,
    IMailbox,
    IPostDispatchHook,
    IInterchainSecurityModule,
    HyperlaneSource,
    HyperlaneDestination
} from "./interfaces/IHyperlaneAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

/// @title  Hyperlane Adapter
/// @notice Routing contract that integrates with the Hyperlane Mailbox.
/// @dev    Gas limits for destination execution are encoded in StandardHookMetadata
///         passed to the Mailbox dispatch/quoteDispatch calls.
///
///         Replay protection is enforced by the Hyperlane Mailbox, which tracks
///         delivered message IDs and reverts on duplicate delivery.
///         See https://docs.hyperlane.xyz/docs/protocol/core/mailbox#replay-protection
///
///         Message ordering is not enforced.
contract HyperlaneAdapter is Auth, IHyperlaneAdapter {
    using CastLib for *;

    /// @dev Cost of executing `handle()` except entrypoint.handle()
    uint256 public constant RECEIVE_COST = 4000;

    IMailbox public immutable mailbox;
    IMessageHandler public immutable entrypoint;

    IInterchainSecurityModule public interchainSecurityModule;
    mapping(uint32 hyperlaneDomain => HyperlaneSource) public sources;
    mapping(uint16 centrifugeId => HyperlaneDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address mailbox_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        mailbox = IMailbox(mailbox_);
    }

    //----------------------------------------------------------------------------------------------
    // Network wiring
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterWiring
    function wire(uint16 centrifugeId, bytes memory data) external auth {
        (uint32 hyperlaneDomain, address adapter) = abi.decode(data, (uint32, address));
        sources[hyperlaneDomain] = HyperlaneSource(centrifugeId, adapter);
        destinations[centrifugeId] = HyperlaneDestination(hyperlaneDomain, adapter);
        emit Wire(centrifugeId, hyperlaneDomain, adapter);
    }

    /// @inheritdoc IAdapterWiring
    function isWired(uint16 centrifugeId) external view returns (bool) {
        return destinations[centrifugeId].hyperlaneDomain != 0;
    }

    /// @inheritdoc IHyperlaneAdapter
    function setIsm(IInterchainSecurityModule ism) external auth {
        interchainSecurityModule = ism;
        emit SetIsm(address(ism));
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageRecipient
    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable {
        HyperlaneSource memory source = sources[origin];
        require(source.addr != address(0) && source.addr == sender.toAddressLeftPadded(), InvalidSource());
        require(msg.sender == address(mailbox), NotMailbox());

        entrypoint.handle(source.centrifugeId, body);
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
        HyperlaneDestination memory destination = destinations[centrifugeId];
        require(destination.hyperlaneDomain != 0, UnknownChainId());

        bytes memory metadata = _metadata(gasLimit + RECEIVE_COST, refund);
        adapterData = mailbox.dispatch{value: msg.value}(
            destination.hyperlaneDomain,
            destination.addr.toBytes32LeftPadded(),
            payload,
            metadata,
            IPostDispatchHook(address(0))
        );
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        HyperlaneDestination memory destination = destinations[centrifugeId];
        require(destination.hyperlaneDomain != 0, UnknownChainId());

        bytes memory metadata = _metadata(gasLimit + RECEIVE_COST, address(this));
        return mailbox.quoteDispatch(
            destination.hyperlaneDomain,
            destination.addr.toBytes32LeftPadded(),
            payload,
            metadata,
            IPostDispatchHook(address(0))
        );
    }

    //----------------------------------------------------------------------------------------------
    // StandardHookMetadata builder
    //----------------------------------------------------------------------------------------------

    uint16 internal constant METADATA_VARIANT = 1;

    /// @dev Build StandardHookMetadata for the Hyperlane Mailbox.
    ///      Layout (packed, NOT abi-encoded):
    ///        [0:2]   uint16  variant (= 1)
    ///        [2:34]  uint256 msgValue (= 0)
    ///        [34:66] uint256 gasLimit
    ///        [66:86] address refundAddress
    function _metadata(uint256 gasLimit, address refund) internal pure returns (bytes memory) {
        return abi.encodePacked(METADATA_VARIANT, uint256(0), gasLimit, refund);
    }
}

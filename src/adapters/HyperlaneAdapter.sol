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
///         passed to the Mailbox dispatch/quoteDispatch calls. Both calls pass the
///         default post-dispatch hook (address(0)), so the encoded gasLimit/msgValue/
///         refund are only honored if the origin Mailbox's configured default hook
///         is an InterchainGasPaymaster-backed hook that reads StandardHookMetadata.
///         This holds on standard Hyperlane deployments; verify it during wiring.
///
///         Replay protection is enforced by the Hyperlane Mailbox, which tracks
///         delivered message IDs and reverts on duplicate delivery.
///         See https://docs.hyperlane.xyz/docs/protocol/core/mailbox#replay-protection
contract HyperlaneAdapter is Auth, IHyperlaneAdapter {
    using CastLib for *;

    /// @dev Cost of executing `handle()` except entrypoint.handle(), reserved per destination chain.
    ///      Covers 1 cold SLOAD (single-slot `sources` struct) + 1 cold CALL (entrypoint) at 4_700, plus
    ///      a flat 5_300 for dispatch, calldata decode, mapping hash, memory and call setup.
    uint256 public constant DEFAULT_RECEIVE_COST = 10_000;

    uint16 public constant MONAD_CENTRIFUGE_ID = 11;
    // Monad reprices cold storage access (2100→8100) and cold account access (2600→10100) per its
    // published opcode schedule (docs.monad.xyz), putting those same two accesses at 18_200 => +13_500
    // over DEFAULT, wrapper allowance unchanged. Mirrors GasService's per-chain reserve.
    uint256 public constant MONAD_RECEIVE_COST = DEFAULT_RECEIVE_COST + 13_500;

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

    /// @inheritdoc IHyperlaneAdapter
    function setIsm(IInterchainSecurityModule ism) external auth {
        require(address(ism) != address(0), IsmZero());
        interchainSecurityModule = ism;
        emit SetIsm(address(ism));
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageRecipient
    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable {
        require(msg.sender == address(mailbox), NotMailbox());

        HyperlaneSource memory source = sources[origin];
        require(source.addr != address(0) && source.addr == sender.toAddressLeftPadded(), InvalidSource());

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

        bytes memory metadata = _metadata(gasLimit + _receiveCost(centrifugeId), refund);
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

        bytes memory metadata = _metadata(gasLimit + _receiveCost(centrifugeId), address(this));
        return mailbox.quoteDispatch(
            destination.hyperlaneDomain,
            destination.addr.toBytes32LeftPadded(),
            payload,
            metadata,
            IPostDispatchHook(address(0))
        );
    }

    /// @dev Per-destination receive reserve added to the requested gas limit; Monad's cold-access
    ///      repricing needs a larger reserve than other chains.
    function _receiveCost(uint16 centrifugeId) internal pure returns (uint256) {
        return centrifugeId == MONAD_CENTRIFUGE_ID ? MONAD_RECEIVE_COST : DEFAULT_RECEIVE_COST;
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStandbyAdapter, IAdapter} from "./interfaces/IStandbyAdapter.sol";

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

/// @title  StandbyAdapter
/// @notice A low-cost cross-chain adapter that wraps another adapter. On `send` it records the message
///         on chain and emits an event, but dispatches nothing. It is meant to be the Nth adapter in an
///         M-of-N quorum (e.g. the 3rd in a 2-of-3): as long as the other adapters are live they reach
///         the threshold on their own and the standby slot stays idle, costing only a single storage
///         write instead of a cross-chain send.
///
///         If one of the live adapters has a liveness issue and the quorum can't be met, anyone can call
///         `forward` to repair delivery: it checks the on-chain record written by `send` and then
///         dispatches the message through the `underlying` adapter, contributing the missing vote. The
///         record check is what keeps the standby vote trustworthy: a payload can be forwarded no more
///         times than it was sent, so the quorum is never weakened.
/// @dev    The `underlying` must be a dedicated adapter instance whose own `entrypoint` is set to this
///         StandbyAdapter (so its inbound `handle` lands here), while this adapter's `entrypoint` is the
///         MultiAdapter. A shared underlying would route its votes to the wrong place.
contract StandbyAdapter is IStandbyAdapter {
    IAdapter public immutable underlying;
    IMessageHandler public immutable entrypoint;

    /// @dev Credits are keyed on (centrifugeId, gasLimit, payload), not session-scoped, so a recorded send
    ///      can still be forwarded after an adapter rotation. This matches normal adapter behaviour — any
    ///      adapter can still deliver an in-flight message post-rotation — and forwards can never exceed
    ///      sends, so the standby vote stays bounded by what was actually sent.
    mapping(bytes32 id => uint256) public forwardable;

    constructor(IMessageHandler entrypoint_, IAdapter underlying_) {
        entrypoint = entrypoint_;
        underlying = underlying_;
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IStandbyAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address)
        external
        payable
        returns (bytes32 id)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        require(msg.value == 0, UnexpectedValue());

        id = _id(centrifugeId, payload, gasLimit);
        forwardable[id]++;

        emit StandbySend(centrifugeId, id, payload, gasLimit);
    }

    /// @inheritdoc IStandbyAdapter
    function estimate(uint16, bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IStandbyAdapter
    function forward(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external payable {
        bytes32 id = _id(centrifugeId, payload, gasLimit);
        require(forwardable[id] > 0, NotForwardable());
        forwardable[id]--;

        require(msg.value >= underlying.estimate(centrifugeId, payload, gasLimit), NotEnoughValue());
        underlying.send{value: msg.value}(centrifugeId, payload, gasLimit, msg.sender);

        emit Forward(centrifugeId, id, payload, gasLimit);
    }

    /// @dev Internal bookkeeping key, not the MultiAdapter payloadId. Hashing in gasLimit binds `forward`
    ///      to the gas originally requested; the single trailing dynamic field keeps it unambiguous.
    function _id(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(centrifugeId, gasLimit, payload));
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IStandbyAdapter
    function handle(uint16 centrifugeId, bytes calldata message) external {
        require(msg.sender == address(underlying), NotUnderlying());
        entrypoint.handle(centrifugeId, message);
    }
}

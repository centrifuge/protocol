// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../core/messaging/interfaces/IMessageHandler.sol";

interface IStandbyAdapter is IAdapter, IMessageHandler {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    /// @notice Emitted by `send` instead of dispatching. In the happy path this is the only effect; the
    ///         message is carried by the other (active) adapters in the quorum. A forwarder reads
    ///         `payload` and `gasLimit` from this log to reconstruct the `forward` call.
    event StandbySend(uint16 indexed centrifugeId, bytes32 indexed id, bytes payload, uint256 gasLimit);

    /// @notice Emitted when a standby send is activated (force-dispatched through the underlying adapter).
    /// @dev    `adapterData` is the value returned by the underlying adapter's `send`, carrying the same
    ///         off-chain delivery metadata that a normal `SendPayload` exposes.
    event Forward(
        uint16 indexed centrifugeId, bytes32 indexed id, bytes payload, uint256 gasLimit, bytes32 adapterData
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotUnderlying();
    error NotForwardable();
    error NotEnoughValue();
    error UnexpectedValue();

    //----------------------------------------------------------------------------------------------
    // Methods
    //----------------------------------------------------------------------------------------------

    /// @notice The wrapped adapter that actually carries the message when activated.
    function underlying() external view returns (IAdapter);

    /// @notice Count of recorded-but-not-forwarded messages for a given (destination, payload) id.
    function forwardable(bytes32 id) external view returns (uint256);

    /// @notice Records the send (a single storage write) so a later `forward` can verify it, but
    ///         dispatches nothing. Returns the id under which the send is recorded. Reverts if any
    ///         value is attached, since the standby path never spends it (it would otherwise strand).
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable
        override
        returns (bytes32 id);

    /// @notice Free in the happy path, so the quorum only pays for the active adapters.
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit)
        external
        view
        override
        returns (uint256);

    /// @notice The minimum `msg.value` a `forward` of this (centrifugeId, payload, gasLimit) tuple accepts:
    ///         the underlying adapter's quote for the uplifted destination gas `forward` requests on the
    ///         caller's behalf. Callers should quote here rather than at `underlying.estimate` directly,
    ///         which would price the recorded `gasLimit` and come in short.
    function estimateForward(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit)
        external
        view
        returns (uint256);

    /// @notice Activate a payload that was previously recorded on standby. Consumes one outstanding
    ///         `forwardable` credit written by `send` for the exact (centrifugeId, payload, gasLimit) tuple
    ///         (so total forwards can never exceed total sends and the gasLimit matches what was sent),
    ///         then dispatches through the underlying adapter, paying its cost from `msg.value`. Any
    ///         excess is forwarded to the underlying adapter, which refunds per its own policy.
    ///         Permissionless: anyone can repair liveness, but only for a genuinely-sent payload.
    /// @dev    The underlying is asked for more destination gas than `gasLimit`, since relaying through
    ///         this adapter adds a frame the sender's provisioning did not account for. The credit stays
    ///         keyed on the `gasLimit` that `send` recorded, so the caller passes that value unchanged.
    function forward(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external payable;

    /// @notice Relay an inbound message from the wrapped adapter to the MultiAdapter, where it counts as
    ///         this adapter's vote. Only reached for forwarded messages, since the standby path never sends.
    /// @dev    Only authenticates that the caller is the `underlying` adapter (prevents impersonation of
    ///         it); validating the cross-chain source is the underlying adapter's responsibility.
    function handle(uint16 centrifugeId, bytes calldata message) external override;
}

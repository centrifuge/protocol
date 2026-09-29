// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStandbyAdapter, IAdapter} from "./interfaces/IStandbyAdapter.sol";

import {IMessageGas} from "../core/messaging/interfaces/IMessageGas.sol";
import {IAdapterEntrypoint} from "../core/messaging/interfaces/IAdapterEntrypoint.sol";

import {IAdapterGasService} from "../admin/interfaces/IAdapterGasService.sol";

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
    IAdapterEntrypoint public immutable entrypoint;

    /// @dev Credits are keyed on (centrifugeId, gasLimit, payload). The payload is what {MultiAdapter.send}
    ///      dispatched, which carries the session id in its leading bytes, so a credit is session-scoped in
    ///      practice and a forward after a blocked session no longer resolves. Forwards can never exceed
    ///      sends, so the standby vote stays bounded by what was actually sent.
    mapping(bytes32 id => uint256) public forwardable;

    constructor(IAdapterEntrypoint entrypoint_, IAdapter underlying_) {
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

        require(msg.value >= estimateForward(centrifugeId, payload, gasLimit), NotEnoughValue());
        bytes32 adapterData = underlying.send{value: msg.value}(
            centrifugeId, payload, _forwardGasLimit(centrifugeId, gasLimit), msg.sender
        );

        emit Forward(centrifugeId, id, payload, gasLimit, adapterData);
    }

    /// @inheritdoc IStandbyAdapter
    function estimateForward(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit)
        public
        view
        returns (uint256)
    {
        return underlying.estimate(centrifugeId, payload, _forwardGasLimit(centrifugeId, gasLimit));
    }

    /// @dev Internal bookkeeping key, not the MultiAdapter payloadId. Hashing in gasLimit binds `forward`
    ///      to the gas originally requested; the single trailing dynamic field keeps it unambiguous.
    function _id(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(centrifugeId, gasLimit, payload));
    }

    /// @dev The destination gas the underlying must request. `gasLimit` was provisioned for the normal
    ///      Executor -> Adapter -> MultiAdapter -> Gateway path (see GasService.messageOverallGasLimit,
    ///      which corrects for those 3 EIP-150 boundaries), but relaying through this adapter inserts a
    ///      4th frame. Reserves this contract's own cost and adds the 64/63 that frame's boundary needs,
    ///      so the entrypoint is entered with as much gas as it would have been on the normal path.
    function _forwardGasLimit(uint16 centrifugeId, uint256 gasLimit) internal view returns (uint256) {
        return (gasLimit + _receiveCost(centrifugeId)) * 64 / 63;
    }

    /// @dev Receive reserve added to the requested gas limit. The gas service holds what this path costs
    ///      and what each destination charges for it, so the adapter only names itself.
    function _receiveCost(uint16 centrifugeId) internal view returns (uint256) {
        IAdapterGasService gasService = IAdapterGasService(address(entrypoint.messageGas()));
        return gasService.receiveCost(centrifugeId, "standby");
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IStandbyAdapter
    function handle(uint16 centrifugeId, bytes calldata message) external {
        require(msg.sender == address(underlying), NotUnderlying());
        entrypoint.handle(centrifugeId, message);
    }

    /// @inheritdoc IAdapterEntrypoint
    /// @dev The vote is the standby's, which is the adapter the MultiAdapter holds in its set.
    function vote(uint16 centrifugeId, bytes calldata payload) external {
        require(msg.sender == address(underlying), NotUnderlying());
        entrypoint.vote(centrifugeId, payload);
    }

    /// @inheritdoc IAdapterEntrypoint
    function execute(uint16 centrifugeId, bytes calldata payload) external {
        require(msg.sender == address(underlying), NotUnderlying());
        entrypoint.execute(centrifugeId, payload);
    }

    /// @inheritdoc IAdapterEntrypoint
    function messageGas() external view returns (IMessageGas) {
        return entrypoint.messageGas();
    }
}

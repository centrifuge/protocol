// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageSender} from "./IMessageSender.sol";
import {IMessageHandler} from "./IMessageHandler.sol";

import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../types/PoolId.sol";

/// @notice Interface for dispatch-only gateway
interface IGateway is IMessageHandler, IMessageSender, IRecoverable {
    struct Funds {
        /// @notice Funds associated to pay for sending messages
        /// @dev    Overflows with type(uint64).max / 10**18 = 7.923 × 10^10 ETH
        uint96 value;
        /// @notice Address where to refund the remaining gas
        IRecoverable refund;
    }

    struct Underpaid {
        uint128 counter;
        uint128 gasLimit;
    }

    event File(bytes32 indexed what, address addr);

    event PrepareMessage(uint16 indexed centrifugeId, PoolId poolId, bytes message);
    event UnderpaidBatch(uint16 indexed centrifugeId, bytes batch);
    event RepayBatch(uint16 indexed centrifugeId, bytes batch);
    event ExecuteMessage(uint16 indexed centrifugeId, bytes message);
    event FailMessage(uint16 indexed centrifugeId, bytes message, bytes error);

    event SetRefundAddress(PoolId poolId, IRecoverable refund);
    event SubsidizePool(PoolId indexed poolId, address indexed sender, uint256 amount);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the batch is ended without starting it.
    error NoBatched();

    /// @notice Dispatched when the gateway is paused.
    error Paused();

    /// @notice Dispatched when a the gateway tries to send an empty message.
    error EmptyMessage();

    /// @notice Dispatched when a the gateway has not enough fuel to send a message.
    /// Only dispatched in PayTransaction method
    error NotEnoughTransactionGas();

    /// @notice Dispatched when a message that has not failed is retried.
    error NotFailedMessage();

    /// @notice Dispatched when a batch that has not been underpaid is repaid.
    error NotUnderpaidBatch();

    /// @notice Dispatched when a batch is repaid with insufficient funds.
    error InsufficientFundsForRepayment();

    /// @notice Dispatched when a message is added to a batch that causes it to exceed the max batch size.
    error ExceedsMaxGasLimit();

    /// @notice Dispatched when a refund address is not set.
    error RefundAddressNotSet();

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @dev    Currently used to update addresses of contract instances.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

    /// @notice Repay an underpaid batch. Send unused funds to subsidy pot of the pool.
    function repay(uint16 centrifugeId, bytes memory batch) external payable;

    /// @notice Retry a failed message.
    function retry(uint16 centrifugeId, bytes memory message) external;

    /// @notice Set an extra gas to the gas limit of the message
    function setExtraGasLimit(uint128 gas) external;

    /// @notice Set the refund address for message associated to a poolId
    function setRefundAddress(PoolId poolId, IRecoverable refund) external;

    /// @notice Pay upfront to later be able to subsidize messages associated to a pool
    function subsidizePool(PoolId poolId) external payable;

    /// @notice Prepays for the TX cost for sending the messages through the adapters
    ///         Currently being called from Vault Router and Hub.
    ///         In order to prepay, the method MUST be called with `msg.value`.
    ///         Called is assumed to have called IGateway.estimate before calling this.
    function startTransactionPayment(address payer) external payable;

    /// @notice Finalize the transaction payment mode, next payments will be subsidized (as default).
    function endTransactionPayment() external;

    /// @notice Add a message to the underpaid storage to be repay and send later.
    /// @dev It only supports one message, not a batch
    function addUnpaidMessage(uint16 centrifugeId, bytes memory message) external;

    /// @notice Initialize batching message
    function startBatching() external;

    /// @notice Finalize batching messages and send the resulting batch message
    function endBatching() external;

    /// @notice Returns the current gateway batching level.
    function isBatching() external view returns (bool);
}

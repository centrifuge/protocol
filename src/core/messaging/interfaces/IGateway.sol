// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageHandler} from "./IMessageHandler.sol";

import {IRecoverable} from "../../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../../types/PoolId.sol";

// Reserved gas amount for processing a message failure (assuming the worst case)
uint256 constant PROCESS_FAIL_MESSAGE_GAS = 35_000;

// Max length for a supported message. Note that a batch can use several messages with this length.
uint256 constant MESSAGE_MAX_LENGTH = 1_000;

// Max length of an error that happens when processing a message.
uint16 constant ERR_MAX_LENGTH = 32 * 4; // enough for most errors

/// @notice Interface for dispatch-only gateway
interface IGateway is IMessageHandler, IRecoverable {
    //----------------------------------------------------------------------------------------------
    // Structs
    //----------------------------------------------------------------------------------------------

    struct Underpaid {
        uint128 gasLimit;
        uint64 counter;
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address addr);
    event UpdateManager(PoolId poolId, address who, bool canManage);
    event BlockOutgoing(uint16 centrifugeId, PoolId poolId, bool isBlocked);
    event PrepareMessage(uint16 indexed centrifugeId, PoolId poolId, bytes message);
    event UnderpaidBatch(uint16 indexed centrifugeId, bytes batch, bytes32 batchHash);
    event RepayBatch(uint16 indexed centrifugeId, bytes batch);
    event ExecuteMessage(uint16 indexed centrifugeId, bytes32 messageHash);
    event FailMessage(uint16 indexed centrifugeId, bytes32 messageHash, bytes error);
    event SetRefundAddress(PoolId poolId, IRecoverable refund);
    event DepositSubsidy(PoolId indexed poolId, address indexed sender, uint256 amount);
    event WithdrawSubsidy(PoolId indexed poolId, address indexed sender, uint256 amount);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the batch is ended without starting it.
    error NoBatched();

    /// @notice Dispatched when the gateway is paused.
    error Paused();

    /// @notice Dispatched when the gateway tries to send an empty message.
    error EmptyMessage();

    /// @notice Dispatched when the message exceeds MESSAGE_MAX_LENGTH.
    error TooLongMessage();

    /// @notice Dispatched when a message that has not failed is retried.
    error NotFailedMessage();

    /// @notice Dispatched when a batch that has not been underpaid is repaid.
    error NotUnderpaidBatch();

    /// @notice Dispatched when the content of a batch doesn't belong to the same pool
    error MalformedBatch();

    /// @notice Dispatched when a message is sent but the gateway is blocked for sending messages
    error OutgoingBlocked();

    /// @notice Dispatched when an account is not valid to withdraw subsidized pool funds
    error CannotRefund();

    /// @notice Dispatched when there is not enough gas to send the message
    error NotEnoughGas();

    /// @notice Dispatched when the batch requires more gas than the destination chain can execute in a single transaction
    error BatchTooExpensive();

    /// @notice Dispatched when a message was batched but there was a payment for it
    error NotPayable();

    /// @notice Dispatched when the callback fails with no error
    error CallFailedWithEmptyRevert();

    /// @notice Dispatched when the callback is called inside the callback
    error CallbackIsLocked();

    /// @notice Dispatched when the user doesn't call lockCallback()
    error CallbackWasNotLocked();

    /// @notice Dispatched when the callback was not from the sender
    error CallbackWasNotFromSender();

    /// @notice Dispatched when there is not enough msg.value to send to the callback
    error NotEnoughValueForCallback();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Used to update an address (state variable) on very rare occasions
    /// @param what The name of the variable to be updated
    /// @param data New address
    function file(bytes32 what, address data) external;

    /// @notice Configures a manager address for a pool
    /// @param poolId PoolId associated to the adapters
    /// @param who Manager address
    /// @param canManage If enabled as manager
    function updateManager(PoolId poolId, address who, bool canManage) external;

    /// @notice Indicates if the gateway for a determined pool can send messages or not
    /// @param centrifugeId Centrifuge ID associated to this block
    /// @param poolId PoolId associated to this block
    /// @param canSend If can send messages or not
    function blockOutgoing(uint16 centrifugeId, PoolId poolId, bool canSend) external;

    //----------------------------------------------------------------------------------------------
    // Message handling
    //----------------------------------------------------------------------------------------------

    /// @notice Repay an underpaid batch
    /// @param centrifugeId The destination chain
    /// @param batch The batch to repay
    /// @param refund Address to refund excess payment
    function repay(uint16 centrifugeId, bytes memory batch, address refund) external payable;

    /// @notice Retry a failed message
    /// @param centrifugeId The destination chain
    /// @param message The message to retry
    function retry(uint16 centrifugeId, bytes memory message) external;

    /// @notice Handling outgoing messages
    /// @param centrifugeId Destination chain
    /// @param message The message to send
    /// @param unpaidMode Tells if storing the message as unpaid if not enough funds
    /// @param refund Address to refund excess payment
    function send(uint16 centrifugeId, bytes calldata message, bool unpaidMode, address refund) external payable;

    //----------------------------------------------------------------------------------------------
    // Batching
    //----------------------------------------------------------------------------------------------

    /// @notice Automatic batching of cross-chain transactions through a callback.
    ///         Any cross-chain transactions triggered in this callback will automatically be batched.
    /// @dev    Should be used like:
    ///         ```
    ///         contract Integration {
    ///             IGateway gateway;
    ///
    ///             function doSomething(PoolId poolId) external {
    ///                 gateway.withBatch(abi.encodeWithSelector(Integration.callback.selector, poolId));
    ///             }
    ///
    ///             function callback(PoolId poolId) external {
    ///                 // Avoid reentrancy to the callback and ensure it's called from withBatch in the same contract:
    ///                 gateway.lockCallback();
    ///
    ///                 // Call several hub, balance sheet, or spoke methods that trigger cross-chain transactions
    ///             }
    ///         }
    ///         ```
    ///
    ///         NOTE: inside callback, `msgSender` should be used instead of msg.sender
    /// @param  callbackData encoding data for the callback method
    /// @param  callbackValue msg.value to send to the callback
    /// @param  refund Address to refund excess payment
    function withBatch(bytes memory callbackData, uint256 callbackValue, address refund) external payable;

    /// @notice Same as withBatch(..), but without sending any msg.value to the callback
    function withBatch(bytes memory callbackData, address refund) external payable;

    /// @notice Ensures the callback is called by withBatch in the same contract.
    /// @dev calling this at the very beginning inside the multicall means:
    ///         - The callback is called from the gateway under `withBatch`.
    ///         - The callback is called from the same contract, because withBatch uses `msg.sender` as target for the callback
    ///         - The callback that uses this can only be called once inside withBatch scope. No reentrancy.
    function lockCallback() external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the current gateway batching level
    /// @return Whether the gateway is currently batching
    function isBatching() external view returns (bool);
}

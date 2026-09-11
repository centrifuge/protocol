// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "./IAdapter.sol";
import {IMessageHandler} from "./IMessageHandler.sol";
import {IProtocolPauser} from "./IProtocolPauser.sol";
import {IMessageProperties} from "./IMessageProperties.sol";

import {IRecoverable} from "../../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../../types/PoolId.sol";

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
    event PrepareMessage(uint16 indexed centrifugeId, PoolId indexed poolId, bytes message);
    event UnderpaidBatch(uint16 indexed centrifugeId, bytes batch, bytes32 batchHash);
    event RepayBatch(uint16 indexed centrifugeId, bytes batch);
    event ExecuteMessage(uint16 indexed centrifugeId, bytes32 messageHash);
    event FailMessage(uint16 indexed centrifugeId, bytes32 messageHash, bytes error);
    event ClearFailedMessage(uint16 indexed centrifugeId, bytes32 messageHash);
    event UpdateManager(PoolId indexed poolId, address indexed who, bool canManage);

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

    /// @notice Dispatched when a message claims to originate from the local chain. A message reaching
    ///         `handle` always crossed a real inter-chain bridge (same-chain hub<->spoke calls bypass
    ///         Gateway entirely via a direct call), so this can only happen for a forged message.
    error CannotBeReceivedLocally();

    /// @notice Dispatched when a message arrives from a chain that is not its expected source.
    error SourceMismatch();

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

    /// @notice Dispatched when trying to create a batch during the send loop
    error ReentrantBatchCreation();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Used to update an address (state variable) on very rare occasions
    /// @param what The name of the variable to be updated
    /// @param data New address
    function file(bytes32 what, address data) external;

    /// @notice Allow/disallow an account to act as gateway manager for a pool.
    /// @dev    WARNING: Gateway managers carry very significant permissions. A manager can call
    ///         `Gateway.handle` directly with an arbitrary centrifugeId and raw message bytes,
    ///         which lets it forge any hub-originated message for its pool — including
    ///         `SetPoolAdapters`, `UpdateManager`, and `ManagerCallFromHub`. This is intentional for
    ///         recovery scenarios (e.g. replaying a valid message that the transport dropped), but
    ///         it means a compromised or malicious manager key is equivalent to hub-level authority
    ///         over that pool. Grant this role only to smart contracts that constrain what messages
    ///         can be injected; never grant it to a plain EOA.
    /// @param poolId The pool identifier
    /// @param who Address to grant or revoke the gateway manager role for
    /// @param canManage True to grant, false to revoke
    function updateManager(PoolId poolId, address who, bool canManage) external;

    /// @notice Remove a failed message so it can no longer be retried.
    /// @dev    Restricted to wards or a manager of the message's pool. Intended for messages that cannot
    ///         be retried successfully and should not persist in the failed queue. It is NOT a reliable
    ///         way to block a message that would currently execute: `retry` is permissionless, so anyone
    ///         can front-run the clear and force execution. Only clear messages that still revert on
    ///         retry. Decrements the failed count by one, mirroring `retry`'s per-instance semantics.
    /// @param centrifugeId The source chain the message originated from
    /// @param message The failed message to remove
    function clearFailedMessage(uint16 centrifugeId, bytes memory message) external;

    //----------------------------------------------------------------------------------------------
    // Message handling
    //----------------------------------------------------------------------------------------------

    /// @notice Repay an underpaid batch
    /// @param centrifugeId The destination chain
    /// @param batch The batch to repay
    /// @param refund Address to refund excess payment
    function repay(uint16 centrifugeId, bytes memory batch, address refund) external payable;

    /// @notice Retry a failed message
    /// @dev    Permissionless: anyone may re-execute a failed message once its failure cause is gone.
    /// @param centrifugeId The source chain the message originated from
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

    /// @notice Protocol's internal chain identifier for this network, distinct from the EVM chain ID
    function localCentrifugeId() external view returns (uint16);

    /// @notice MultiAdapter used for outbound message dispatch and inbound quorum verification
    function adapter() external view returns (IAdapter);

    /// @notice Handler that routes confirmed inbound cross-chain messages to their target contracts
    function processor() external view returns (IMessageHandler);

    /// @notice Provides gas cost estimates and message type metadata for cross-chain messages
    function messageProperties() external view returns (IMessageProperties);

    /// @notice ProtocolGuardian that can pause/unpause all cross-chain messaging
    function pauser() external view returns (IProtocolPauser);

    /// @notice Returns whether `who` is a gateway manager for `poolId`.
    ///         See {updateManager} for the security implications of this role.
    function manager(PoolId poolId, address who) external view returns (bool);

    /// @notice Returns the underpaid batch info for a given chain and batch hash
    /// @param centrifugeId The destination chain identifier
    /// @param batchHash The hash of the underpaid batch
    /// @return gasLimit The gas limit for the batch
    /// @return counter The number of underpaid instances
    function underpaid(uint16 centrifugeId, bytes32 batchHash) external view returns (uint128 gasLimit, uint64 counter);

    /// @notice Returns the number of failed message instances for a given chain and message hash
    /// @param centrifugeId The source chain identifier
    /// @param messageHash The hash of the failed message
    /// @return The count of failed instances
    function failedMessages(uint16 centrifugeId, bytes32 messageHash) external view returns (uint256);

    /// @notice Returns the current gateway batching level
    /// @return Whether the gateway is currently batching
    function isBatching() external view returns (bool);
}

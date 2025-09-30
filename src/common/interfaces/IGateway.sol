// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageHandler} from "./IMessageHandler.sol";

import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../types/PoolId.sol";

/// @notice Interface for dispatch-only gateway
interface IGateway is IMessageHandler, IRecoverable {
    struct Funds {
        /// @notice Funds associated to pay for sending messages
        /// @dev    Overflows with type(uint64).max / 10**18 = 7.923 × 10^10 ETH
        uint96 value;
        /// @notice Address where to refund the remaining gas
        IRecoverable refund;
    }

    struct Underpaid {
        uint128 gasLimit;
        uint64 counter;
    }

    event File(bytes32 indexed what, address addr);

    event UpdateManager(PoolId poolId, address who, bool canManage);
    event BlockOutgoing(uint16 centrifugeId, PoolId poolId, bool isBlocked);

    event PrepareMessage(uint16 indexed centrifugeId, PoolId poolId, bytes message);
    event UnderpaidBatch(uint16 indexed centrifugeId, bytes batch, bytes32 batchHash);
    event RepayBatch(uint16 indexed centrifugeId, bytes batch);
    event ExecuteMessage(uint16 indexed centrifugeId, bytes message, bytes32 messageHash);
    event FailMessage(uint16 indexed centrifugeId, bytes message, bytes32 messageHash, bytes error);

    event SetRefundAddress(PoolId poolId, IRecoverable refund);
    event DepositSubsidy(PoolId indexed poolId, address indexed sender, uint256 amount);
    event WithdrawSubsidy(PoolId indexed poolId, address indexed sender, uint256 amount);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the batch is ended without starting it.
    error NoBatched();

    /// @notice Dispatched when the gateway is paused.
    error Paused();

    /// @notice Dispatched when a the gateway tries to send an empty message.
    error EmptyMessage();

    /// @notice Dispatched when a message that has not failed is retried.
    error NotFailedMessage();

    /// @notice Dispatched when a batch that has not been underpaid is repaid.
    error NotUnderpaidBatch();

    /// @notice Dispatched when a message is added to a batch that causes it to exceed the max batch size.
    error ExceedsMaxGasLimit();

    /// @notice Dispatched when a handle is called without enough gas to process the message.
    error NotEnoughGasToProcess();

    /// @notice Dispatched when a message is sent but the gateway is blocked for sending messages
    error OutgoingBlocked();

    /// @notice Dispatched when an account is not valid to withdraw subsidized pool funds
    error CannotRefund();

    /// @notice Dispatched when there is not enough gas to send the message
    error NotEnoughGas();

    /// @notice Dispatched when a the message was batched but there was a payment for it
    error NotPayable();

    /// @notice Dispatched when withBatch is called but the system is already batching
    ///         (it's inside of another withBatch level)
    error AlreadyBatching();

    /// @notice Dispatched when the callback fails with no error
    error CallFailedWithEmptyRevert();

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @dev    Currently used to update addresses of contract instances.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

    /// @notice Configures a manager address for a pool.
    /// @param  poolId PoolId associated to the adapters
    /// @param  who Manager address
    /// @param  canManage if enabled as manager
    function updateManager(PoolId poolId, address who, bool canManage) external;

    /// @notice Indicates if the gateway for a determined pool can send messages or not
    /// @param centrifugeId Centrifuge ID associated to this block
    /// @param  poolId PoolId associated to this block
    /// @param  canSend If can send messages or not
    function blockOutgoing(uint16 centrifugeId, PoolId poolId, bool canSend) external;

    /// @notice Sets the gateway in unpaid mode where any call to send will store the message as unpaid
    /// if not enough funds instead of sending the actual message.
    function setUnpaidMode(bool enabled) external;

    /// @notice Repay an underpaid batch.
    function repay(uint16 centrifugeId, bytes memory batch, address refund) external payable;

    /// @notice Retry a failed message.
    function retry(uint16 centrifugeId, bytes memory message) external;

    /// @notice Handling outgoing messages.
    /// @param centrifugeId Destination chain
    function send(uint16 centrifugeId, bytes calldata message, uint128 extraGasLimit, address refund) external payable;

    /// @notice Calls a method that should be in the same contract as the caller, as a callback.
    ///         The method called will be wrapped inside startBatching and endBatching,
    ///         so any method call inside that requires messaging will be batched.
    /// @param  data encoding data for the callback method
    /// @dev    Helper contract that enables integrations to automatically batch multiple cross-chain transactions.
    ///         Should be used like:
    ///         ```
    ///         contract Integration {
    ///             ICrosschainBatcher batcher;
    ///
    ///             function doSomething(PoolId poolId) external {
    ///                 batcher.withBatch(abi.encodeWithSelector(Integration.callback.selector, poolId));
    ///             }
    ///
    ///             function callback(PoolId poolId) external {
    ///                 require(batcher.sender() == address(this));
    ///                 // Call several hub, balance sheet, or spoke methods that trigger cross-chain transactions
    ///             }
    ///         }
    ///         ```
    function withBatch(address target, bytes memory data, address refund) external payable;

    /// @notice Returns the current gateway batching level.
    function isBatching() external view returns (bool);

    /// @notice Returns the current gateway batching level.
    function batcher() external view returns (address);
}

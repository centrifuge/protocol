// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {IGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {PoolId} from "src/common/types/PoolId.sol";

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @notice Interface for dispatch-only gateway
interface IGateway is IMessageHandler, IMessageSender, IGatewayHandler {
    /// @dev Each adapter struct is packed with the quorum to reduce SLOADs on handle
    struct Adapter {
        /// @notice Starts at 1 and maps to id - 1 as the index on the adapters array
        uint8 id;
        /// @notice Number of votes required for a message to be executed
        uint8 quorum;
        /// @notice Each time the quorum is decreased, a new session starts which invalidates old votes
        uint64 activeSessionId;
    }

    struct InboundBatch {
        /// @dev Counts are stored as integers (instead of boolean values) to accommodate duplicate
        ///      messages (e.g. two investments from the same user with the same amount) being
        ///      processed in parallel. The entire struct is packed in a single bytes32 slot.
        ///      Max uint16 = 65,535 so at most 65,535 duplicate messages can be processed in parallel.
        uint16[MAX_ADAPTER_COUNT] votes;
        /// @notice Each time adapters are updated, a new session starts which invalidates old votes
        uint64 sessionId;
        bytes pendingBatch;
    }

    struct Funds {
        /// @notice Funds associated to pay for sending messages
        /// @dev    Overflows with type(uint64).max / 10**18 = 7.923 × 10^10 ETH
        uint96 value;
        /// @notice Address where to refund the remaining gas
        IRecoverable refund;
    }

    // Used to bypass stack too deep issue
    struct SendData {
        bytes32 batchHash;
        uint128 batchGasLimit;
        bytes32 payloadId;
        uint256[] gasCost;
    }

    // --- Events ---
    event PrepareMessage(uint16 indexed centrifugeId, PoolId poolId, bytes message);
    event UnderpaidBatch(uint16 indexed centrifugeId, bytes batch);
    event RepayBatch(uint16 indexed centrifugeId, bytes batch);
    event SendBatch(
        uint16 indexed centrifugeId,
        bytes32 indexed payloadId,
        bytes batch,
        IAdapter adapter,
        bytes32 adapterData,
        address refund
    );
    event SendProof(
        uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes32 batchHash, IAdapter adapter, bytes32 adapterData
    );
    event HandleBatch(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes batch, IAdapter adapter);
    event HandleProof(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes32 batchHash, IAdapter adapter);
    event ExecuteMessage(uint16 indexed centrifugeId, bytes message);
    event FailMessage(uint16 indexed centrifugeId, bytes message, bytes error);

    event RecoverMessage(IAdapter adapter, bytes message);
    event RecoverProof(IAdapter adapter, bytes32 batchHash);
    event InitiateRecovery(uint16 centrifugeId, bytes32 batchHash, IAdapter adapter);
    event DisputeRecovery(uint16 centrifugeId, bytes32 batchHash, IAdapter adapter);
    event ExecuteRecovery(uint16 centrifugeId, bytes message, IAdapter adapter);

    event File(bytes32 indexed what, uint16 centrifugeId, IAdapter[] adapters);
    event File(bytes32 indexed what, address addr);

    event SetRefundAddress(PoolId poolId, IRecoverable refund);
    event SubsidizePool(PoolId indexed poolId, address indexed sender, uint256 amount);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the batch is ended without starting it.
    error NoBatched();

    /// @notice Dispatched when the gateway is paused.
    error Paused();

    /// @notice Dispatched when the gateway is configured with a number of adapter exceeding the maximum.
    error ExceedsMax();

    /// @notice Dispatched when the gateway is configured with an empty adapter set.
    error EmptyAdapterSet();

    /// @notice Dispatched when the gateway is configured with duplicate adapters.
    error NoDuplicatesAllowed();

    /// @notice Dispatched when the gateway tries to handle a message from an adaptet not contained in the adapter set.
    error InvalidAdapter();

    /// @notice Dispatched when the gateway tries to recover a recovery message, which is not allowed.
    error RecoveryPayloadRecovered();

    /// @notice Dispatched when the gateway tries to handle a proof from a non proof adapter.
    error NonProofAdapter();

    /// @notice Dispatched when the gateway tries to handle a batch from a non message adapter.
    error NonBatchAdapter();

    /// @notice Dispatched when a recovery message is executed without being initiated.
    error RecoveryNotInitiated();

    /// @notice Dispatched when a recovery message is executed without waiting the challenge period.
    error RecoveryChallengePeriodNotEnded();

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
    error ExceedsMaxBatchSize();

    /// @notice Dispatched when a refund address is not set.
    error RefundAddressNotSet();

    // --- Administration ---
    /// @notice Used to update an array of addresses ( state variable ) on very rare occasions.
    /// @dev    Currently it is used to update the supported adapters.
    /// @param  what The name of the variable to be updated.
    /// @param  centrifugeId Chain where the adapters are associated to.
    /// @param  value New addresses.
    function file(bytes32 what, uint16 centrifugeId, IAdapter[] calldata value) external;

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @dev    Currently used to update addresses of contract instances.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

    /// @notice Repay an underpaid batch. Send unused funds to subsidy pot of the pool.
    function repay(uint16 centrifugeId, bytes memory batch) external payable;

    /// @notice Set the refund address for message associated to a poolId
    function setRefundAddress(PoolId poolId, IRecoverable refund) external;

    /// @notice Pay upfront to later be able to subsidize messages associated to a pool
    function subsidizePool(PoolId poolId) external payable;

    /// @notice Prepays for the TX cost for sending the messages through the adapters
    ///         Currently being called from Vault Router only.
    ///         In order to prepay, the method MUST be called with `msg.value`.
    ///         Called is assumed to have called IGateway.estimate before calling this.
    function payTransaction(address payer) external payable;

    /// @notice Initialize batching message
    function startBatching() external;

    /// @notice Finalize batching messages and send the resulting batch message
    function endBatching() external;

    /// @notice Execute message recovery. After the challenge period, the recovery can be executed.
    ///         If a malign adapter initiates message recovery,
    ///         governance can dispute and immediately cancel the recovery, using any other valid adapter.
    ///
    ///         Only 1 recovery can be outstanding per message hash. If multiple adapters fail at the same time,
    ///         these will need to be recovered serially (increasing the challenge period for each failed adapter).
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  adapter Adapter's address that the recovery is targeting
    /// @param  message Hash of the message to be recovered
    function executeRecovery(uint16 centrifugeId, IAdapter adapter, bytes calldata message) external;

    // --- Helpers ---
    /// @notice A view method of the current quorum.abi
    /// @dev    Quorum shows the amount of votes needed in order for a message to be dispatched further.
    ///         The quorum is taken from the first adapter which is always the length of active adapters.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// return  Needed amount
    function quorum(uint16 centrifugeId) external view returns (uint8);

    /// @notice Gets the current active routers session id.
    /// @dev    When the adapters are updated with new ones,
    ///         each new set of adapters has their own sessionId.
    ///         Currently it uses sessionId of the previous set and
    ///         increments it by 1. The idea of an activeSessionId is
    ///         to invalidate any incoming messages from previously used adapters.
    /// @param  centrifugeId Chain where the adapter is configured for
    function activeSessionId(uint16 centrifugeId) external view returns (uint64);

    /// @notice Counts how many times each incoming messages has been received per adapter.
    /// @dev    It supports parallel messages ( duplicates ). That means that the incoming messages could be
    ///         the result of two or more independ request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  batchHash The hash value of the incoming batch message.
    function votes(uint16 centrifugeId, bytes32 batchHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory);

    /// @notice Used to calculate overall cost for bridging a payload on the first adapter and settling
    ///         on the destination chain and bridging its payload proofs on n-1 adapter
    ///         and settling on the destination chain.
    /// @param  payload Used in gas cost calculations.
    /// @dev    Currenly the payload is not taken into consideration.
    /// @return total Total cost for sending one message and corresponding proofs on through all adapters
    function estimate(uint16 centrifugeId, bytes calldata payload) external view returns (uint256 total);

    /// @notice Returns the address of the adapter at the given id.
    /// @param  centrifugeId Chain where the adapter is configured for
    function adapters(uint16 centrifugeId, uint256 id) external view returns (IAdapter);

    /// @notice Returns the timestamp when the given recovery can be executed.
    /// @param  centrifugeId Chain where the adapter is configured for
    function recoveries(uint16 centrifugeId, IAdapter adapter, bytes32 batchHash)
        external
        view
        returns (uint256 timestamp);

    /// @notice Returns the current gateway batching level.
    function isBatching() external view returns (bool);
}

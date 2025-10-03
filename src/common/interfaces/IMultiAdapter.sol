// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "./IAdapter.sol";
import {IMessageHandler} from "./IMessageHandler.sol";

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @notice Interface for handling several adapters transparently
interface IMultiAdapter is IAdapter, IMessageHandler {
    /// @dev Each adapter struct is packed with the quorum to reduce SLOADs on handle
    struct Adapter {
        /// @notice Starts at 1 and maps to id - 1 as the index on the adapters array
        uint8 id;
        /// @notice Number of votes required for a message to be executed
        uint8 quorum;
        /// @notice Each time the quorum is decreased, a new session starts which invalidates old votes
        uint64 activeSessionId;
    }

    struct Inbound {
        /// @dev Counts are stored as integers (instead of boolean values) to accommodate duplicate
        ///      messages (e.g. two investments from the same user with the same amount) being
        ///      processed in parallel. The entire struct is packed in a single bytes32 slot.
        ///      Max uint16 = 65,535 so at most 65,535 duplicate messages can be processed in parallel.
        uint16[MAX_ADAPTER_COUNT] votes;
        /// @notice Each time adapters are updated, a new session starts which invalidates old votes
        uint64 sessionId;
        bytes pending;
    }

    event File(bytes32 indexed what, address addr);
    event File(bytes32 indexed what, uint16 centrifugeId, IAdapter[] adapters);

    event HandlePayload(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes payload, IAdapter adapter);
    event HandleProof(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes32 payloadHash, IAdapter adapter);
    event SendPayload(
        uint16 indexed centrifugeId,
        bytes32 indexed payloadId,
        bytes payload,
        IAdapter adapter,
        bytes32 adapterData,
        address refund
    );
    event SendProof(
        uint16 indexed centrifugeId,
        bytes32 indexed payloadId,
        bytes32 payloadHash,
        IAdapter adapter,
        bytes32 adapterData
    );

    event InitiateRecovery(uint16 centrifugeId, bytes32 payloadHash, IAdapter adapter);
    event DisputeRecovery(uint16 centrifugeId, bytes32 payloadHash, IAdapter adapter);
    event ExecuteRecovery(uint16 centrifugeId, bytes message, IAdapter adapter);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the contract is configured with an empty adapter set.
    error EmptyAdapterSet();

    /// @notice Dispatched when the contract is configured with a number of adapter exceeding the maximum.
    error ExceedsMax();

    /// @notice Dispatched when the contract is configured with duplicate adapters.
    error NoDuplicatesAllowed();

    /// @notice Dispatched when the contract tries to handle a message from an adaptet not contained in the adapter set.
    error InvalidAdapter();

    /// @notice Dispatched when the contract is configured with an empty adapter set.
    error NonProofAdapter();

    /// @notice Dispatched when the contract tries to handle a payload from a non message adapter.
    error NonPayloadAdapter();

    /// @notice Dispatched when the contract tries to recover a recovery message, which is not allowed.
    error RecoveryPayloadRecovered();

    /// @notice Dispatched when a recovery message is executed without being initiated.
    error RecoveryNotInitiated();

    /// @notice Dispatched when a recovery message is executed without waiting the challenge period.
    error RecoveryChallengePeriodNotEnded();

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @dev    Currently used to update addresses of contract instances.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

    /// @notice Used to update an array of addresses ( state variable ) on very rare occasions.
    /// @dev    Currently it is used to update the supported adapters.
    /// @param  what The name of the variable to be updated.
    /// @param  centrifugeId Chain where the adapters are associated to.
    /// @param  value New addresses.
    function file(bytes32 what, uint16 centrifugeId, IAdapter[] calldata value) external;

    /// @notice Initiate recovery of a payload.
    function initiateRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash) external;

    /// @notice Dispute recovery of a payload.
    function disputeRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash) external;

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
    ///         the result of two or more independent request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  payloadHash The hash value of the incoming message.
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory);

    /// @notice Returns the address of the adapter at the given id.
    /// @param  centrifugeId Chain where the adapter is configured for
    function adapters(uint16 centrifugeId, uint256 id) external view returns (IAdapter);

    /// @notice Returns the timestamp when the given recovery can be executed.
    /// @param  centrifugeId Chain where the adapter is configured for
    function recoveries(uint16 centrifugeId, IAdapter adapter, bytes32 payloadHash)
        external
        view
        returns (uint256 timestamp);
}

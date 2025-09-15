// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "./IAdapter.sol";
import {IMessageHandler} from "./IMessageHandler.sol";

import {PoolId} from "../types/PoolId.sol";

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @notice Interface for handling several adapters transparently
interface IMultiAdapter is IAdapter, IMessageHandler {
    /// @dev Each adapter struct is packed with the quorum to reduce SLOADs on handle
    struct Adapter {
        /// @notice Starts at 1 and maps to id - 1 as the index on the adapters array
        uint8 id;
        /// @notice Number of configured adapters
        uint8 quorum;
        /// @notice Number of votes required for a message to be executed. Less-equal to quorum.
        uint8 threshold;
        /// @notice Index in the adapter array to start consider the adapter as recovery adapter.
        uint8 recoveryIndex;
        /// @notice Each time the quorum is decreased, a new session starts which invalidates old votes
        uint64 activeSessionId;
    }

    struct Inbound {
        /// @dev Counts are stored as integers (instead of boolean values) to accommodate duplicate
        ///      messages (e.g. two investments from the same user with the same amount) being
        ///      processed in parallel. The entire struct is packed in a single bytes32 slot.
        ///      Max int16 = 32,767 so at most 32,767 duplicate messages can be processed in parallel.
        int16[MAX_ADAPTER_COUNT] votes;
        /// @notice Each time adapters are updated, a new session starts which invalidates old votes
        uint64 sessionId;
    }

    event File(bytes32 indexed what, address addr);

    event SetAdapters(uint16 centrifugeId, PoolId poolId, IAdapter[] adapters, uint8 threshold, uint8 recoveryIndex);

    event HandlePayload(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes payload, IAdapter adapter);
    event SendPayload(
        uint16 indexed centrifugeId,
        bytes32 indexed payloadId,
        bytes payload,
        IAdapter adapter,
        bytes32 adapterData,
        address refund
    );

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the contract is configured with an empty adapter set.
    error EmptyAdapterSet();

    /// @notice Dispatched when the threshold number is higher than the number of configured adapters (aka quorum).
    error ThresholdHigherThanQuorum();

    /// @notice Dispatched when the recovery index is higher than the number of configured adapters (aka quorum).
    error RecoveryIndexHigherThanQuorum();

    /// @notice Dispatched when the contract is configured with a number of adapter exceeding the maximum.
    error ExceedsMax();

    /// @notice Dispatched when the contract is configured with duplicate adapters.
    error NoDuplicatesAllowed();

    /// @notice Dispatched when the contract tries to handle a message from an adaptet not contained in the adapter set.
    error InvalidAdapter();

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

    /// @notice Configure new adapters for a determined pool.
    ///         Messages sent but not yet received when this is executed will be lost.
    /// @param  centrifugeId Chain where the adapters are associated to.
    /// @param  poolId PoolId associated to the adapters
    /// @param  adapters New adapter addresses already deployed.
    /// @param  threshold Minimum number of adapters required to process the messages
    ///         If not wanted a threshold set `adapters.length` value
    /// @param  recoveryIndex Index in adapters array from where consider the adapter as recovery adapter.
    ///         If not wanted a recoveryIndex set `adapters.length` value
    ///
    ///         A recovery adapter is an adapter that does not decrease their votes below 0.
    ///         it is, it can never have a debt on messages not received.
    ///         It can be used to easily emulate receiving a missing message by some of the others adapters.
    ///
    ///         i.e: Suppose a configuration of `[Adapter1, Adapter2, RecoveryAdapter]` with threshold 2.
    ///         Both `Adapter1` and `Adapter2` will need always need to handle the message, each one, to process it.
    ///         In case some of those fail, the losing vote can be recover through the `RecoveryAdapter`` to reach
    ///         threshold 2.
    function setAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external;

    /// @notice Number of total configured adapters for a pool.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  poolId PoolId associated to the adapters
    /// @return  Needed amount
    function quorum(uint16 centrifugeId, PoolId poolId) external view returns (uint8);

    /// @notice Number of required votes to consider a message valid for processing. It's lower-equal than quorum.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  poolId PoolId associated to the adapters
    /// return  Needed amount
    function threshold(uint16 centrifugeId, PoolId poolId) external view returns (uint8);

    /// @notice Index in the adapter array to start consider the adapter as recovery adapter.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  poolId PoolId associated to the adapters
    /// return  Needed amount
    function recoveryIndex(uint16 centrifugeId, PoolId poolId) external view returns (uint8);

    /// @notice Gets the current active routers session id.
    /// @dev    When the adapters are updated with new ones,
    ///         each new set of adapters has their own sessionId.
    ///         Currently it uses sessionId of the previous set and
    ///         increments it by 1. The idea of an activeSessionId is
    ///         to invalidate any incoming messages from previously used adapters.
    /// @param  centrifugeId Chain where the adapters are configured for
    /// @param  poolId PoolId associated to the adapters
    function activeSessionId(uint16 centrifugeId, PoolId poolId) external view returns (uint64);

    /// @notice Counts how many times each incoming messages has been received per adapter.
    /// @dev    It supports parallel messages ( duplicates ). That means that the incoming messages could be
    ///         the result of two or more independent request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  payloadHash The hash value of the incoming message.
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (int16[MAX_ADAPTER_COUNT] memory);

    /// @notice Returns the address of the adapter at the given id.
    /// @param  centrifugeId Chain where the adapters are configured for
    /// @param  poolId PoolId associated to the adapters
    function adapters(uint16 centrifugeId, PoolId poolId, uint256 id) external view returns (IAdapter);

    /// @notice Returns the list of adapters that will be used for a pool.
    /// @param  centrifugeId Chain where the adapters are configured for
    /// @param  poolId PoolId associated to the adapters
    /// @return pool adapters or global adapters if they were not configured
    function poolAdapters(uint16 centrifugeId, PoolId poolId) external view returns (IAdapter[] memory);
}

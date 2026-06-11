// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "./IAdapter.sol";
import {IMessageHandler} from "./IMessageHandler.sol";
import {IMessageProperties} from "./IMessageProperties.sol";

import {PoolId} from "../../types/PoolId.sol";

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @notice Interface for handling several adapters transparently
interface IMultiAdapter is IAdapter, IMessageHandler {
    //----------------------------------------------------------------------------------------------
    // Structs
    //----------------------------------------------------------------------------------------------

    /// @dev Each adapter struct is packed with the quorum, threshold and recoveryIndex to reduce SLOADs on handle
    struct Adapter {
        /// @notice Starts at 1 and maps to id - 1 as the index on the adapters array
        uint8 id;
        /// @notice Number of configured adapters
        uint8 quorum;
        /// @notice Number of votes required for a message to be executed. Less-equal to quorum
        uint8 threshold;
        /// @notice Index in the adapter array to start consider the adapter as recovery adapter
        uint8 recoveryIndex;
    }

    struct Adapters {
        /// @notice Session id of the currently active adapter set
        uint16 sessionId;
        /// @notice List of currently active adapters
        IAdapter[] list;
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address addr);
    event SetAdapters(uint16 centrifugeId, PoolId poolId, IAdapter[] adapters, uint8 threshold, uint8 recoveryIndex);
    event DenySession(uint16 centrifugeId, PoolId poolId, uint16 sessionId);
    event HandlePayload(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes payload, IAdapter adapter);
    event SendPayload(
        uint16 indexed centrifugeId,
        bytes32 indexed payloadId,
        bytes payload,
        IAdapter adapter,
        bytes32 adapterData,
        uint256 gasLimit,
        uint256 gasPaid,
        address refund
    );
    event UpdateManager(PoolId poolId, address who, bool canManage);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

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

    /// @notice Dispatched when the contract tries to handle a message from an adapter not contained in the adapter set.
    error InvalidAdapter();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Used to update an address (state variable) on very rare occasions
    /// @param what The name of the variable to be updated
    /// @param data New address
    function file(bytes32 what, address data) external;

    /// @notice Configure new adapters for a determined pool.
    /// @param  centrifugeId Chain where the adapters are associated to.
    /// @param  poolId PoolId associated to the adapters
    /// @param  adapters New adapter addresses already deployed.
    ///         If the array is empty, it disables the usage for messages of that pool.
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

    /// @notice Remove adapter details for a given session, preventing those adapters from voting on messages.
    /// @param  centrifugeId Chain where the adapters are configured for
    /// @param  poolId PoolId associated to the adapters
    /// @param  sessionId Session to revoke
    function denySession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external;

    /// @notice Configures a manager address for a pool
    /// @param poolId PoolId associated to the adapters
    /// @param who Manager address
    /// @param canManage If enabled as manager
    function updateManager(PoolId poolId, address who, bool canManage) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Protocol's internal chain identifier for this network, distinct from the EVM chain ID
    function localCentrifugeId() external view returns (uint16);

    /// @notice Gateway that receives confirmed messages once adapter quorum is reached
    function gateway() external view returns (IMessageHandler);

    /// @notice Provides gas cost estimates and message type metadata for cross-chain messages
    function messageProperties() external view returns (IMessageProperties);

    /// @notice Returns whether an address is a manager for a given pool
    /// @param poolId The pool to check
    /// @param who The address to check
    function manager(PoolId poolId, address who) external view returns (bool);

    /// @notice Returns the currently active session id for a given chain and pool
    /// @param centrifugeId The source chain identifier
    /// @param poolId The pool identifier
    function activeSessionId(uint16 centrifugeId, PoolId poolId) external view returns (uint16);

    /// @notice Returns the adapter at a given index for a specific session
    /// @param centrifugeId The source chain identifier
    /// @param poolId The pool identifier
    /// @param sessionId The session identifier
    /// @param index The index in the adapter array
    function adapters(uint16 centrifugeId, PoolId poolId, uint16 sessionId, uint256 index)
        external
        view
        returns (IAdapter);

    /// @notice Number of total configured adapters for a pool
    /// @param centrifugeId Chain where the adapter is configured for
    /// @param poolId PoolId associated to the adapters
    /// @return Needed amount
    function quorum(uint16 centrifugeId, PoolId poolId) external view returns (uint8);

    /// @notice Number of required votes to consider a message valid for processing
    /// @dev It's lower-equal than quorum
    /// @param centrifugeId Chain where the adapter is configured for
    /// @param poolId PoolId associated to the adapters
    /// @return Needed amount
    function threshold(uint16 centrifugeId, PoolId poolId) external view returns (uint8);

    /// @notice Index in the adapter array to start consider the adapter as recovery adapter
    /// @param centrifugeId Chain where the adapter is configured for
    /// @param poolId PoolId associated to the adapters
    /// @return Recovery index
    function recoveryIndex(uint16 centrifugeId, PoolId poolId) external view returns (uint8);

    /// @notice Counts how many times each incoming messages has been received per adapter.
    /// @dev    It supports parallel messages ( duplicates ). That means that the incoming messages could be
    ///         the result of two or more independent request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  payloadHash The hash value of the incoming message.
    /// @return The votes array
    function votes(uint16 centrifugeId, bytes32 payloadHash) external view returns (int16[MAX_ADAPTER_COUNT] memory);

    /// @notice Returns the active adapter set for a pool
    /// @param centrifugeId Chain where the adapters are configured for
    /// @param poolId PoolId associated to the adapters
    /// @return The adapters list and last session id
    function activeAdapters(uint16 centrifugeId, PoolId poolId) external view returns (Adapters memory);
}

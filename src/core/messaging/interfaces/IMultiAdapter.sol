// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "./IAdapter.sol";
import {IMessageHandler} from "./IMessageHandler.sol";
import {IAdapterEntrypoint} from "./IAdapterEntrypoint.sol";
import {IMessageProperties} from "./IMessageProperties.sol";

import {PoolId} from "../../types/PoolId.sol";

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @notice Interface for handling several adapters transparently
interface IMultiAdapter is IAdapter, IAdapterEntrypoint {
    //----------------------------------------------------------------------------------------------
    // Structs
    //----------------------------------------------------------------------------------------------

    /// @dev Each adapter struct is packed with the quorum and threshold to reduce SLOADs on handle
    struct Adapter {
        /// @notice Starts at 1 and maps to id - 1 as the index on the adapters array
        uint8 id;
        /// @notice Number of configured adapters
        uint8 quorum;
        /// @notice Number of votes required for a message to be executed. Less-equal to quorum
        uint8 threshold;
    }

    struct Adapters {
        /// @notice Session id of the currently active adapter set
        uint16 sessionId;
        /// @notice List of currently active adapters
        IAdapter[] list;
    }

    /// @dev Stash holding a blocked session's configuration so it can be restored on unblock.
    ///      A session is blocked iff its stashed list is non-empty.
    struct BlockedSession {
        uint8 threshold;
        bool wasActive;
        IAdapter[] list;
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address addr);
    event SetAdapters(
        uint16 centrifugeId, PoolId indexed poolId, uint16 sessionId, IAdapter[] adapters, uint8 threshold
    );
    event BlockSession(uint16 centrifugeId, PoolId indexed poolId, uint16 sessionId);
    event UnblockSession(uint16 centrifugeId, PoolId indexed poolId, uint16 sessionId);
    event Vote(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes payload, IAdapter adapter);
    event Execute(uint16 indexed centrifugeId, bytes32 indexed payloadId, bytes payload, IAdapter adapter);
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
    event UpdateManager(PoolId indexed poolId, address indexed who, bool canManage);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the contract is configured with an empty adapter set.
    error EmptyAdapterSet();

    /// @notice Dispatched when the threshold number is higher than the number of configured adapters (aka quorum).
    error ThresholdHigherThanQuorum();

    /// @notice Dispatched when the threshold is zero while adapters are configured, which would let any
    ///         single adapter forward payloads without consensus.
    error ZeroThreshold();

    /// @notice Dispatched when the provided `targetSessionId` does not equal the pool's next session id, so a
    ///         reordered, stale or reentrant configuration cannot desync the two endpoints under the same id.
    error UnexpectedSessionId();

    /// @notice Dispatched when the contract is configured with a number of adapter exceeding the maximum.
    error ExceedsMax();

    /// @notice Dispatched when the contract is configured with duplicate adapters.
    error NoDuplicatesAllowed();

    /// @notice Dispatched when the contract tries to handle a message from an adapter not contained in the adapter set.
    error InvalidAdapter();

    /// @notice Dispatched when trying to block a session that has no adapters configured.
    error SessionNotConfigured();

    /// @notice Dispatched when trying to unblock a session that is not currently blocked.
    error SessionNotBlocked();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Used to update an address (state variable) on very rare occasions
    /// @param what The name of the variable to be updated
    /// @param data New address
    function file(bytes32 what, address data) external;

    /// @notice Configure new adapters for a determined pool.
    /// @dev    Bumps the pool's local sessionId to `targetSessionId`, which must equal the pool's next session id
    ///         (current + 1), reverting otherwise. The normal path (`Hub.setAdapters`) derives that id once and
    ///         uses it for both endpoints, so the remote bumps its session in lockstep; a reordered, stale or
    ///         reentrant configuration fails closed. A manager calling this directly (a low-level recovery path,
    ///         e.g. `AdapterFailover`) passes its own next session id and is responsible for ensuring the
    ///         resulting sessionId matches the other endpoint, otherwise messages wrapped with the new session
    ///         won't verify.
    ///
    ///         Recovery runbook when an adapter of the active set starts reverting on `estimate`/`send`. Such an
    ///         adapter vetoes every outbound message of the pool, including the rotation itself, so `Hub.setAdapters`
    ///         and `Hub.updateManager` are unusable: both travel over the broken set before it can be replaced.
    ///         1. Identify the culprit: `activeAdapters()` returns the live set and its session id, and simulating
    ///            `estimate` per adapter isolates which one reverts.
    ///         2. Rotate the sending chain locally: a pool adapter manager calls this function directly, passing
    ///            `nextActiveSessionId()`. `AdapterFailover` is the intended wrapper, gating the rotation behind a
    ///            steward and a hub-vetoable timelock. Appoint that manager while the adapters are still healthy;
    ///            once the set is broken, a chain without one can only be reached by a Root spell on that chain.
    ///         3. Install the mirrored set on the other endpoint the same way. Each call only advances the session
    ///            counter of the chain it runs on, so from aligned endpoints one rotation per side keeps them aligned.
    ///         4. Verify that alignment before resuming traffic: `activeSessionId(remoteId, poolId)` here must equal
    ///            `activeSessionId(localCentrifugeId, poolId)` there. If a side lagged, call this function again on it
    ///            with the same set until the ids match, since a payload wrapped with a session id the receiver never
    ///            configured is rejected with {InvalidAdapter}.
    ///         5. Retire the superseded session with `blockSession()` on each receiving side, once the messages sent
    ///            under it have been delivered, following the flow documented in {IHub-setAdapters}.
    ///         6. Re-issue the operations that reverted during the outage: they were never queued, so there is no
    ///            underpaid backlog to repay.
    /// @param  centrifugeId Chain where the adapters are associated to.
    /// @param  poolId PoolId associated to the adapters
    /// @param  adapters New adapter addresses already deployed.
    ///         If the array is empty, it disables the usage for messages of that pool.
    /// @param  threshold Minimum number of adapters required to process the messages.
    ///         Must be at least 1 when `adapters` is non-empty; set `adapters.length` for full consensus.
    /// @param  targetSessionId The session id to install; must equal the pool's next session id (current + 1)
    function setAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint16 targetSessionId
    ) external;

    /// @notice Mark a session as blocked, preventing its adapters from voting on incoming messages and, if it is the
    ///         active session, from sending outgoing messages. The session can later be recovered with unblockSession().
    /// @param  centrifugeId Chain where the adapters are configured for
    /// @param  poolId PoolId associated to the adapters
    /// @param  sessionId Session to block
    function blockSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external;

    /// @notice Recover a previously blocked session, re-enabling its adapters.
    /// @param  centrifugeId Chain where the adapters are configured for
    /// @param  poolId PoolId associated to the adapters
    /// @param  sessionId Session to unblock
    function unblockSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external;

    /// @notice Configures a manager address for a pool
    /// @dev    WARNING: a manager carries very significant permissions equivalent to controlling every
    ///         adapter configured for the pool. It can call `handle`/`vote`/`execute` on behalf of any
    ///         configured adapter address, and by doing so once per adapter can single-handedly reach
    ///         quorum and forward an arbitrary payload to the gateway as if real cross-chain consensus
    ///         had been reached — bypassing the M-of-N adapter security model entirely for that pool.
    ///         Grant this role only to smart contracts that constrain what can be submitted; never grant
    ///         it to a plain EOA. Mirrors the same trust level as `IGateway.updateManager`.
    /// @param poolId PoolId associated to the adapters
    /// @param who Manager address
    /// @param canManage If enabled as manager
    function updateManager(PoolId poolId, address who, bool canManage) external;

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @notice Manager-driven variant of {IMessageHandler-handle}. Adapters submit via the two-argument
    ///         `handle`, identifying themselves through `msg.sender`. Here a manager of the payload's
    ///         pool submits on behalf of `adapter`, naming which configured adapter the message
    ///         belongs to. Equivalent to a vote followed by a possible execute.
    /// @param  centrifugeId Source chain identifier
    /// @param  payload The wrapped payload (session-id prefixed)
    /// @param  adapter The configured adapter the message is attributed to
    function handle(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) external;

    /// @notice Manager-driven variant of {IAdapterEntrypoint-vote}. A manager of the payload's
    ///         pool casts a vote on behalf of `adapter` without ever executing it.
    /// @param  centrifugeId Source chain identifier
    /// @param  payload The wrapped payload (session-id prefixed)
    /// @param  adapter The configured adapter the vote is attributed to
    function vote(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) external;

    /// @notice Manager-driven variant of {IAdapterEntrypoint-execute}. A manager of the payload's
    ///         pool executes an already-threshold-reached payload, attributing it to `adapter`. Reverts with
    ///         {NotEnoughVotes} if the threshold is not met. `adapter` only identifies the session config and
    ///         the {Execute} attribution; no vote of its own is cast.
    /// @param  centrifugeId Source chain identifier
    /// @param  payload The wrapped payload (session-id prefixed)
    /// @param  adapter A configured adapter the execution is attributed to
    function execute(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) external;

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

    /// @notice Returns the next session id to install for a given chain and pool (current + 1).
    ///         Callers are expected to pass this as the `targetSessionId` to {setAdapters}.
    /// @param centrifugeId The source chain identifier
    /// @param poolId The pool identifier
    function nextActiveSessionId(uint16 centrifugeId, PoolId poolId) external view returns (uint16);

    /// @notice Returns whether a session has been blocked
    /// @param centrifugeId The source chain identifier
    /// @param poolId The pool identifier
    /// @param sessionId The session identifier
    function blockedSession(uint16 centrifugeId, PoolId poolId, uint16 sessionId) external view returns (bool);

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

    /// @notice Counts how many times each incoming messages has been received per adapter.
    /// @dev    It supports parallel messages ( duplicates ). That means that the incoming messages could be
    ///         the result of two or more independent request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  centrifugeId Chain where the adapter is configured for
    /// @param  voteKey The vote-tally key: `keccak256(abi.encodePacked(routedPoolId, wrappedPayload))`, so a
    ///         global-set vote and a pool-set vote on the same bytes land in separate slots.
    /// @return The votes array
    function votes(uint16 centrifugeId, bytes32 voteKey) external view returns (int16[MAX_ADAPTER_COUNT] memory);

    /// @notice Returns the active adapter set for a pool
    /// @param centrifugeId Chain where the adapters are configured for
    /// @param poolId PoolId associated to the adapters
    /// @return The adapters list and last session id
    function activeAdapters(uint16 centrifugeId, PoolId poolId) external view returns (Adapters memory);
}

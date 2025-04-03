// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {PoolId} from "src/common/types/PoolId.sol";

uint8 constant MAX_ADAPTER_COUNT = 8;

/// @notice Interface for dispatch-only gateway
interface IGateway is IMessageHandler, IMessageSender, IGatewayHandler {
    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    error NoBatched();

    enum PaymentMethod {
        None,
        TopUp,
        Subsidized
    }

    struct BatchLocator {
        uint16 chainId;
        PoolId poolId;
    }

    /// @dev Each adapter struct is packed with the quorum to reduce SLOADs on handle
    struct Adapter {
        /// @notice Starts at 1 and maps to id - 1 as the index on the adapters array
        uint8 id;
        /// @notice Number of votes required for a message to be executed
        uint8 quorum;
        /// @notice Each time the quorum is decreased, a new session starts which invalidates old votes
        uint64 activeSessionId;
    }

    struct Message {
        /// @dev Counts are stored as integers (instead of boolean values) to accommodate duplicate
        ///      messages (e.g. two investments from the same user with the same amount) being
        ///      processed in parallel. The entire struct is packed in a single bytes32 slot.
        ///      Max uint16 = 65,535 so at most 65,535 duplicate messages can be processed in parallel.
        uint16[MAX_ADAPTER_COUNT] votes;
        /// @notice Each time adapters are updated, a new session starts which invalidates old votes
        uint64 sessionId;
        bytes pendingMessage;
    }

    // --- Events ---
    event ProcessMessage(uint16 chainId, bytes message, IAdapter adapter);
    event ProcessProof(uint16 chainId, bytes32 messageHash, IAdapter adapter);
    event ExecuteMessage(uint16 chainId, bytes message, IAdapter adapter);
    event SendMessage(bytes message);
    event RecoverMessage(IAdapter adapter, bytes message);
    event RecoverProof(IAdapter adapter, bytes32 messageHash);
    event InitiateMessageRecovery(uint16 chainId, bytes32 messageHash, IAdapter adapter);
    event DisputeMessageRecovery(uint16 chainId, bytes32 messageHash, IAdapter adapter);
    event ExecuteMessageRecovery(uint16 chainId, bytes message, IAdapter adapter);
    event File(bytes32 indexed what, uint16 chainId, IAdapter[] adapters);
    event File(bytes32 indexed what, address addr);
    event ReceiveNativeTokens(PoolId indexed poolId, address indexed sender, uint256 amount);

    // --- Administration ---
    /// @notice Used to update an array of addresses ( state variable ) on very rare occasions.
    /// @dev    Currently it is used to update the supported adapters.
    /// @param  what The name of the variable to be updated.
    /// @param  chainId Chain ID.
    /// @param  value New addresses.
    function file(bytes32 what, uint16 chainId, IAdapter[] calldata value) external;

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @dev    Currently used to update addresses of contract instances.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

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
    /// @param  chainId Chain where the adapter is configured for
    /// @param  adapter Adapter's address that the recovery is targeting
    /// @param  message Hash of the message to be recovered
    function executeMessageRecovery(uint16 chainId, IAdapter adapter, bytes calldata message) external;

    /// @notice Prepays for the TX cost for sending through the adapters
    ///         and Centrifuge Chain
    /// @dev    It can be called only through endorsed contracts.
    ///         Currently being called from Vault Router only.
    ///         In order to prepay, the method MUST be called with `msg.value`.
    ///         Called is assumed to have called IGateway.estimate before calling this.
    function topUp() external payable;

    // --- Helpers ---
    /// @notice A view method of the current quorum.abi
    /// @dev    Quorum shows the amount of votes needed in order for a message to be dispatched further.
    ///         The quorum is taken from the first adapter.
    ///         Current quorum is the amount of all adapters.
    /// @param  chainId Chain where the adapter is configured for
    /// return  Needed amount
    function quorum(uint16 chainId) external view returns (uint8);

    /// @notice Gets the current active routers session id.
    /// @dev    When the adapters are updated with new ones,
    ///         each new set of adapters has their own sessionId.
    ///         Currently it uses sessionId of the previous set and
    ///         increments it by 1. The idea of an activeSessionId is
    ///         to invalidate any incoming messages from previously used adapters.
    /// @param  chainId Chain where the adapter is configured for
    function activeSessionId(uint16 chainId) external view returns (uint64);

    /// @notice Counts how many times each incoming messages has been received per adapter.
    /// @dev    It supports parallel messages ( duplicates ). That means that the incoming messages could be
    ///         the result of two or more independ request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  chainId Chain where the adapter is configured for
    /// @param  messageHash The hash value of the incoming message.
    function votes(uint16 chainId, bytes32 messageHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory);

    /// @notice Used to calculate overall cost for bridging a payload on the first adapter and settling
    ///         on the destination chain and bridging its payload proofs on n-1 adapter
    ///         and settling on the destination chain.
    /// @param  payload Used in gas cost calculations.
    /// @dev    Currenly the payload is not taken into consideration.
    /// @return perAdapter An array of cost values per adapter. Each value is how much it's going to cost
    ///         for a message / proof to be passed through one router and executed on the recipient chain
    /// @return total Total cost for sending one message and corresponding proofs on through all adapters
    function estimate(uint16 chainId, bytes calldata payload)
        external
        view
        returns (uint256[] memory perAdapter, uint256 total);

    /// @notice Returns the address of the adapter at the given id.
    /// @param  chainId Chain where the adapter is configured for
    function adapters(uint16 chainId, uint256 id) external view returns (IAdapter);

    /// @notice Returns the number of adapters.
    /// @param  chainId Chain where the adapter is configured for
    function adapterCount(uint16 chainId) external view returns (uint256);

    /// @notice Returns the timestamp when the given recovery can be executed.
    /// @param  chainId Chain where the adapter is configured for
    function recoveries(uint16 chainId, IAdapter adapter, bytes32 messageHash)
        external
        view
        returns (uint256 timestamp);

    /// @notice Returns the current gateway batching level.
    function isBatching() external view returns (bool);
}

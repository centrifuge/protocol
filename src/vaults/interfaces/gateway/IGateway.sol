// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

uint8 constant MAX_ADAPTER_COUNT = 8;

interface IGateway {
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
    event ProcessMessage(bytes message, address adapter);
    event ProcessProof(bytes32 messageHash, address adapter);
    event ExecuteMessage(bytes message, address adapter);
    event SendMessage(bytes message);
    event RecoverMessage(address adapter, bytes message);
    event RecoverProof(address adapter, bytes32 messageHash);
    event InitiateMessageRecovery(bytes32 messageHash, address adapter);
    event DisputeMessageRecovery(bytes32 messageHash, address adapter);
    event ExecuteMessageRecovery(bytes message, address adapter);
    event File(bytes32 indexed what, address[] adapters);
    event File(bytes32 indexed what, address instance);
    event File(bytes32 indexed what, uint8 messageId, address manager);
    event File(bytes32 indexed what, address caller, bool isAllowed);
    event ReceiveNativeTokens(address indexed sender, uint256 amount);

    /// @notice Returns the address of the adapter at the given id.
    function adapters(uint256 id) external view returns (address);

    /// @notice Returns the address of the contract that handles the given message id.
    function messageHandlers(uint8 messageId) external view returns (address);

    /// @notice Returns the timestamp when the given recovery can be executed.
    function recoveries(address adapter, bytes32 messageHash) external view returns (uint256 timestamp);

    // --- Administration ---
    /// @notice Used to update an array of addresses ( state variable ) on very rare occasions.
    /// @dev    Currently it is used to update the supported adapters.
    /// @param  what The name of the variable to be updated.
    /// @param  value New addresses.
    function file(bytes32 what, address[] calldata value) external;

    /// @notice Used to update an address ( state variable ) on very rare occasions.
    /// @dev    Currently used to update addresses of contract instances.
    /// @param  what The name of the variable to be updated.
    /// @param  data New address.
    function file(bytes32 what, address data) external;

    /// @notice Used to update a mapping ( state variables ) on very rare occasions.
    /// @dev    Currently used to update any custom handlers for a specific message type.
    ///         data1 is the message id from MessagesLib.Call and data2 could be any
    ///         custom instance of a contract that will handle that call.
    /// @param  what The name of the variable to be updated.
    /// @param  data1 The key of the mapping.
    /// @param  data2 The value of the mapping
    function file(bytes32 what, uint8 data1, address data2) external;

    /// @notice Used to update a mapping ( state variables ) on very rare occasions.
    /// @dev    Manages who is allowed to call `this.topUp`
    ///
    /// @param what The name of the variable to be updated - `payers`
    /// @param caller Address of the payer allowed to top-up
    /// @param isAllower Whether the `caller` is allowed to top-up or not
    function file(bytes32 what, address caller, bool isAllower) external;

    // --- Incoming ---
    /// @notice Handles incoming messages, proofs, and recoveries.
    /// @dev    Assumes adapters ensure messages cannot be confirmed more than once.
    /// @param  payload Incoming message from the Centrifuge Chain passed through adapters.
    function handle(bytes calldata payload) external;

    /// @notice Governance on Centrifuge Chain can initiate message recovery. After the challenge period,
    ///         the recovery can be executed. If a malign adapter initiates message recovery, governance on
    ///         Centrifuge Chain can dispute and immediately cancel the recovery, using any other valid adapter.
    /// @param  adapter Adapter that the recovery was targeting
    /// @param  messageHash Hash of the message being disputed
    function disputeMessageRecovery(address adapter, bytes32 messageHash) external;

    /// @notice Governance on Centrifuge Chain can initiate message recovery. After the challenge period,
    ///         the recovery can be executed. If a malign adapter initiates message recovery, governance on
    ///         Centrifuge Chain can dispute and immediately cancel the recovery, using any other valid adapter.
    ///
    ///         Only 1 recovery can be outstanding per message hash. If multiple adapters fail at the same time,
    ///         these will need to be recovered serially (increasing the challenge period for each failed adapter).
    /// @param  adapter Adapter's address that the recovery is targeting
    /// @param  message Hash of the message to be recovered
    function executeMessageRecovery(address adapter, bytes calldata message) external;

    // --- Outgoing ---
    /// @notice Sends outgoing messages to the Centrifuge Chain.
    /// @dev    Sends 1 message to the first adapter with the full message,
    ///         and n-1 messages to the other adapters with proofs (hash of message).
    ///         This ensures message uniqueness (can only be executed on the destination once).
    ///         Source could be either Centrifuge router or EoA or any contract
    ///         that calls the ERC7540Vault contract directly.
    /// @param  message Message to be send. Either the message itself or a hash value of it ( proof ).
    /// @param  source Entry point of the transaction.
    ///         Used to determine whether it is eligible for TX cost payment.
    function send(bytes calldata message, address source) external payable;

    /// @notice Prepays for the TX cost for sending through the adapters
    ///         and Centrifuge Chain
    /// @dev    It can be called only through endorsed contracts.
    ///         Currently being called from Centrifuge Router only.
    ///         In order to prepay, the method MUST be called with `msg.value`.
    ///         Called is assumed to have called IGateway.estimate before calling this.
    function topUp() external payable;

    // --- Helpers ---
    /// @notice A view method of the current quorum.abi
    /// @dev    Quorum shows the amount of votes needed in order for a message to be dispatched further.
    ///         The quorum is taken from the first adapter.
    ///         Current quorum is the amount of all adapters.
    /// return  Needed amount
    function quorum() external view returns (uint8);

    /// @notice Gets the current active routers session id.
    /// @dev    When the adapters are updated with new ones,
    ///         each new set of adapters has their own sessionId.
    ///         Currently it uses sessionId of the previous set and
    ///         increments it by 1. The idea of an activeSessionId is
    ///         to invalidate any incoming messages from previously used adapters.
    function activeSessionId() external view returns (uint64);

    /// @notice Counts how many times each incoming messages has been received per adapter.
    /// @dev    It supports parallel messages ( duplicates ). That means that the incoming messages could be
    ///         the result of two or more independ request from the user of the same type.
    ///         i.e. Same user would like to deposit same underlying asset with the same amount more then once.
    /// @param  messageHash The hash value of the incoming message.
    function votes(bytes32 messageHash) external view returns (uint16[MAX_ADAPTER_COUNT] memory);

    /// @notice Used to calculate overall cost for bridging a payload on the first adapter and settling
    ///         on the destination chain and bridging its payload proofs on n-1 adapter
    ///         and settling on the destination chain.
    /// @param  payload Used in gas cost calculations.
    /// @dev    Currenly the payload is not taken into consideration.
    /// @return perAdapter An array of cost values per adapter. Each value is how much it's going to cost
    ///         for a message / proof to be passed through one router and executed on Centrifuge Chain
    /// @return total Total cost for sending one message and corresponding proofs on through all adapters
    function estimate(bytes calldata payload) external view returns (uint256[] memory perAdapter, uint256 total);

    /// @notice Used to check current state of the `caller` and whether they are allowed to call
    ///         `this.topUp` or not.
    /// @param  caller Address to check
    /// @return isAllowed Whether the `caller` `isAllowed to call `this.topUp()`
    function payers(address caller) external view returns (bool isAllowed);
}

interface IMessageHandler {
    /// @notice Handling incoming messages from Centrifuge Chain.
    /// @param  message Incoming message
    function handle(bytes memory message) external;
}

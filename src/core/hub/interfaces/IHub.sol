// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IFeeHook} from "./IFeeHook.sol";
import {IValuation} from "./IValuation.sol";
import {IHubRegistry} from "./IHubRegistry.sol";
import {ISnapshotHook} from "./ISnapshotHook.sol";
import {IHoldings, HoldingAccount} from "./IHoldings.sol";
import {IAccounting, JournalEntry} from "./IAccounting.sol";
import {IHubRequestManager} from "./IHubRequestManager.sol";
import {IShareClassManager} from "./IShareClassManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {IAdapter} from "../../messaging/interfaces/IAdapter.sol";
import {VaultUpdateKind} from "../../messaging/libraries/MessageLib.sol";
import {IMultiAdapter} from "../../messaging/interfaces/IMultiAdapter.sol";
import {IHubMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IGateway} from "../../messaging/interfaces/IGateway.sol";
import {IManifest} from "./IManifest.sol";

/// @notice Account types used by Hub
enum AccountType {
    /// @notice Account for tracking assets
    Asset,
    /// @notice Account for tracking equities
    Equity,
    /// @notice Account for tracking losses
    Loss,
    /// @notice Account for tracking profits
    Gain,
    /// @notice Account for tracking expenses
    Expense,
    /// @notice Account for tracking liabilities
    Liability
}

struct PendingOp {
    uint48 executeAfter;
    address submitter;
}

/// @notice Interface with all methods available in the system used by actors
interface IHub {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event NotifyPool(uint16 indexed centrifugeId, PoolId indexed poolId);
    event NotifyShareClass(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId);
    event NotifyShareMetadata(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, string name, string symbol
    );
    event UpdateShareHook(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 hook);
    event NotifySharePrice(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, D18 poolPerShare, uint64 computedAt
    );
    event NotifyAssetPrice(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset
    );
    event UpdateRestriction(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes payload);
    event SetSpokeRequestManager(uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 indexed manager);
    event UpdateBalanceSheetManager(
        uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 indexed manager, bool canManage
    );
    event UpdateGatewayManager(
        uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 indexed manager, bool canManage
    );
    event UpdateVault(
        PoolId indexed poolId, ShareClassId scId, AssetId assetId, bytes32 vaultOrFactory, VaultUpdateKind kind
    );
    event UpdateContract(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 target, bytes payload
    );
    event ForwardTransferShares(
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        PoolId indexed poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    );
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when a batch is already being processed and a nested entry into
    ///         {await} or {execute} would clobber the active submitter context.
    error AlreadyInBatch();

    /// @notice Dispatched when the pool can not be unlocked by the caller
    error NotManager();

    /// @notice Dispatched when an invalid centrifuge ID is set in the pool ID.
    error InvalidPoolId();

    /// @notice Dispatched when an invalid combination of account IDs is passed.
    error InvalidAccountCombination();

    error InvalidRequestManager();

    error RequestManagerCallFailed();

    error OperationNotPending();

    error TimelockNotReady(uint48 executeAfter);

    error ExecutionFailed(bytes result);

    /// @notice Dispatched when the post-batch callback reverts.
    error CallbackFailed(bytes result);

    /// @notice Dispatched when a manager function is called directly instead of via {await}.
    error MustAwait();

    /// @notice Dispatched when a call inside a batch targets a different pool than the batch poolId.
    error PoolIdMismatch();

    /// @notice Dispatched when `await` is called with an empty batch.
    error EmptyBatch();

    /// @notice Dispatched when a call inside a batch targets a selector that would allow nested
    ///         batching and therefore bypass the manifest (await/execute/cancel).
    error ForbiddenSelector();

    /// @notice Dispatched when the gateway tries to invoke {executeBatch} from outside a withBatch.
    error NotGateway();

    //----------------------------------------------------------------------------------------------
    // Manifest & timelock events
    //----------------------------------------------------------------------------------------------

    event OperationSubmitted(
        bytes32 indexed opId,
        PoolId indexed poolId,
        address indexed submitter,
        uint64 nonce,
        uint48 executeAfter,
        bytes[] calls,
        bytes callback
    );
    event OperationExecuted(bytes32 indexed opId);
    event OperationCanceled(bytes32 indexed opId);
    event SetManifest(PoolId indexed poolId, IManifest manifest);

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the gateway contract used for cross-chain batching
    function gateway() external view returns (IGateway);

    /// @notice Returns the holdings contract
    /// @return The holdings contract instance
    function holdings() external view returns (IHoldings);

    /// @notice Returns the accounting contract
    /// @return The accounting contract instance
    function accounting() external view returns (IAccounting);

    /// @notice Returns the hub registry contract
    /// @return The hub registry contract instance
    function hubRegistry() external view returns (IHubRegistry);

    /// @notice Returns the message sender contract
    /// @return The message sender contract instance
    function sender() external view returns (IHubMessageSender);

    /// @notice Returns the share class manager contract
    /// @return The share class manager contract instance
    function shareClassManager() external view returns (IShareClassManager);

    /// @notice Hook that calculates and applies protocol fees on NAV updates
    function feeHook() external view returns (IFeeHook);

    /// @notice Handles multi-protocol message verification and routing for cross-chain communication
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update (accepts 'hubRegistry', 'accounting', 'holdings', 'gateway', 'sender')
    /// @param data Address of the new contract
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @notice Notify to a CV instance that a new pool is available
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param refund Address to receive excess gas refund
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable;

    /// @notice Notify to a CV instance that a new share class is available
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param hook The hook address of the share class
    /// @param refund Address to receive excess gas refund
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable;

    /// @notice Notify to a CV instance that share metadata has updated
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param refund Address to receive excess gas refund
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) external payable;

    /// @notice Update on a CV instance the hook of a share token
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param hook The new hook address
    /// @param refund Address to receive excess gas refund
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / SHARE_UNIT
    /// @param poolId The pool identifier
    /// @param scId Identifier of the share class
    /// @param centrifugeId Chain to where the share price is notified
    /// @param refund Address to receive excess gas refund
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / ASSET_UNIT
    /// @param poolId The pool identifier
    /// @param scId Identifier of the share class
    /// @param assetId Identifier of the asset
    /// @param refund Address to receive excess gas refund
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId, address refund) external payable;

    /// @notice Attach custom data to a pool
    /// @param poolId The pool identifier
    /// @param metadata Custom metadata to attach
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable;

    /// @notice Set snapshot hook for a pool
    /// @param poolId The pool identifier
    /// @param hook The snapshot hook contract
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable;

    /// @notice Update name & symbol of share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param name New name for the share class
    /// @param symbol New symbol for the share class
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable;

    /// @notice Allow/disallow an account to interact as hub manager this pool
    /// @param poolId The pool identifier
    /// @param who Address to update manager status for
    /// @param canManage Whether the address can manage the pool
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable;

    /// @notice Allow/disallow an account to interact as request manager
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain where the request manager will operate
    /// @param hubManager Hub request manager contract
    /// @param spokeManager Spoke request manager address
    /// @param refund Address to receive excess gas refund
    function setRequestManager(
        PoolId poolId,
        uint16 centrifugeId,
        IHubRequestManager hubManager,
        bytes32 spokeManager,
        address refund
    ) external payable;

    /// @notice Allow/disallow an account to interact as balance sheet manager for this pool
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain where the balance sheet manager will operate
    /// @param who Address to update manager status for
    /// @param canManage Whether the address can manage the balance sheet
    /// @param refund Address to receive excess gas refund
    function updateBalanceSheetManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable;

    /// @notice Add a new share class to the pool
    /// @param poolId The pool identifier
    /// @param name Name for the share class
    /// @param symbol Symbol for the share class
    /// @param salt Salt for deterministic deployment
    /// @return scId The newly created share class identifier
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId);

    /// @notice Update remotely a restriction
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param payload Content of the restriction update to execute
    /// @param extraGasLimit Extra gas limit for remote computation
    /// @param refund Address to receive excess gas refund
    function updateRestriction(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Updates a vault based on VaultUpdateKind
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param vaultOrFactory The address of the vault or the factory, depending on the kind value
    /// @param kind The kind of action applied
    /// @param extraGasLimit Extra gas limit for remote computation
    /// @param refund Address to receive excess gas refund
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Update remotely an existing vault
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param target Contract where to execute in CV
    /// @param payload Content of the update to execute
    /// @param extraGasLimit Extra gas limit for remote computation
    /// @param refund Address to receive excess gas refund
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Update the price per share of a share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param pricePoolPerShare The new price per share
    /// @param computedAt Timestamp when the price was computed (must be <= block.timestamp)
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt)
        external
        payable;

    /// @notice Create a new holding associated to the asset in a share class.
    ///         It will register the different accounts used for holdings.
    ///         The accounts have to be created beforehand.
    ///         The same account can be used for different kinds.
    ///         e.g.: The equity, gain, and loss account can be the same account.
    ///         They can also be shared across assets.
    ///         e.g.: All assets can use the same equity account.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation Used to transform between payment assets and pool currency
    /// @param assetAccount Used to track the asset value
    /// @param equityAccount Used to track the equity value
    /// @param gainAccount Used to track the gain value
    /// @param lossAccount Used to track the loss value
    function initializeHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) external payable;

    /// @notice Create a new liability associated to the asset in a share class.
    ///         It will register the different accounts used for holdings.
    ///         The accounts have to be created beforehand.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation Used to transform between the holding asset and pool currency
    /// @param expenseAccount Used to track the expense value
    /// @param liabilityAccount Used to track the liability value
    function initializeLiability(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId expenseAccount,
        AccountId liabilityAccount
    ) external payable;

    /// @notice Updates the pool currency value of this holding based of the associated valuation
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Updates whether the holding represents a liability or not
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param isLiability Whether the holding is a liability
    function updateHoldingIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability)
        external
        payable;

    /// @notice Updates the valuation used by a holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation Used to transform between the holding asset and pool currency
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable;

    /// @notice Set an account of a holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param kind The account type
    /// @param accountId The account identifier to set
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable;

    /// @notice Creates an account
    /// @param poolId The pool identifier
    /// @param accountId The new AccountId used
    /// @param isDebitNormal Determines if the account should be used as debit-normal or credit-normal
    function createAccount(PoolId poolId, AccountId accountId, bool isDebitNormal) external payable;

    /// @notice Attach custom data to an account
    /// @param poolId The pool identifier
    /// @param account The account identifier
    /// @param metadata Custom metadata to attach
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable;

    /// @notice Perform an accounting entries update
    /// @param poolId The pool identifier
    /// @param debits Array of debit journal entries
    /// @param credits Array of credit journal entries
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external payable;

    /// @notice Set adapters for a pool in another chain.
    /// @dev    Changing adapters increments the session ID, which invalidates any messages that were sent
    ///         before the update but not yet delivered. To avoid failed deliveries, block outgoing messages on all
    ///         affected chains before calling this function, and unblock after the new configuration has been delivered:
    ///
    ///         1. Grant gateway manager role on each affected chain via `updateGatewayManager`
    ///         2. Call `gateway.blockOutgoing(canSend=false)` on each affected chain to pause outgoing messages
    ///         3. Wait for all pending message deliveries to complete
    ///         4. Call `setAdapters` with the new configuration
    ///         5. Wait for the adapter update to be delivered
    ///         6. Call `gateway.blockOutgoing(canSend=true)` on each affected chain to resume
    ///
    /// @param poolId Pool associated to this configuration
    /// @param centrifugeId Chain where to perform the adapter configuration
    /// @param localAdapters Adapter addresses in this chain
    /// @param remoteAdapters Adapter addresses in the remote chain
    /// @param threshold Minimum number of adapters required to process the messages
    /// @param recoveryIndex Index in adapters array from where consider the adapter as recovery adapter
    /// @param refund Address to receive excess gas refund
    function setAdapters(
        PoolId poolId,
        uint16 centrifugeId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        uint8 recoveryIndex,
        address refund
    ) external payable;

    /// @notice Update a gateway manager for a pool
    /// @param poolId Pool associated to this configuration
    /// @param centrifugeId Chain where to perform the gateway configuration
    /// @param who Address used as manager
    /// @param canManage If enabled as manager
    /// @param refund Address to receive excess gas refund
    function updateGatewayManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable;

    /// @notice Update accounting for a holding amount change
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param isPositive Whether the change is positive
    /// @param diff The amount of change
    function updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        payable;

    /// @notice Update accounting for a holding value change
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param isPositive Whether the change is positive
    /// @param diff The amount of change
    function updateAccountingValue(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        payable;

    //----------------------------------------------------------------------------------------------
    // Manifest & timelock methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the manifest for a pool
    function manifest(PoolId poolId) external view returns (IManifest);

    /// @notice Returns pending operation info
    function pending(bytes32 opId) external view returns (uint48 executeAfter, address submitter);

    /// @notice Returns the next nonce that {await} will assign for `poolId` (current + 1).
    function awaitNonce(PoolId poolId) external view returns (uint64);

    /// @notice Set the manifest for a pool. Routes through {await} like any other manager action.
    function setManifest(PoolId poolId, IManifest manifest_) external;

    /// @notice Submit a batch of Hub manager calls for `poolId`. Always async: this function
    ///         queues the batch as a pending operation and returns. The batch only runs when
    ///         {execute} is called, which must be a separate call (same transaction is fine via
    ///         {awaitAndExecute}, but never inline within {await} itself). This keeps the API
    ///         predictable: {await} has no side effects on the batch, only on the pending-ops
    ///         mapping.
    ///
    ///         Each call's calldata is passed through the pool's manifest; the batch is
    ///         timelocked by the longest individual delay. A delay of zero means {execute} may
    ///         run right away.
    ///
    /// @param poolId   The pool every call in the batch must target as its first argument.
    /// @param calls    Array of ABI-encoded Hub calldata. Must be non-empty. All-or-nothing:
    ///                 any per-call revert during {execute} reverts the whole batch (and the
    ///                 callback). The caller MUST size the batch — every call plus the post-batch
    ///                 callback — to fit within the block gas limit; the manifest runs at await
    ///                 time, gas is not measured. If {execute} OOGs the pending op stays put and
    ///                 can be retried with more gas; a batch that's structurally too large to
    ///                 ever fit is permanently stuck and `cancel` is the only recourse. For
    ///                 failure-tolerant flows, queue each call as a separate await.
    /// @param callback Optional payload to call back on the submitter AFTER the batch runs in
    ///                 {execute}. Empty bytes = no callback. The active submitter context is
    ///                 cleared before the callback fires so the callback may invoke `hub.await`
    ///                 to chain another batch.
    /// @return nonce   Per-pool nonce assigned to this pending op (also in {OperationSubmitted}).
    /// @return opId    keccak256(abi.encode(poolId, nonce, calls, callback)).
    function await(PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        external
        returns (uint64 nonce, bytes32 opId);

    /// @notice Execute a pending batch once its timelock has passed. Any manager of `poolId`
    ///         may call this; the original submitter's identity is restored for the replayed
    ///         calls. msg.value funds cross-chain message payment via the gateway batch.
    /// @param poolId   The pool the batch was awaited against.
    /// @param nonce    The per-pool nonce assigned to the pending op.
    /// @param calls    The exact array passed to {await}.
    /// @param callback The exact callback passed to {await}.
    function execute(PoolId poolId, uint64 nonce, bytes[] calldata calls, bytes calldata callback) external payable;

    /// @notice Convenience: {await} then {execute} in one transaction. Reverts with
    ///         {TimelockNotReady} if the manifest assigns any delay. Provided so integrators
    ///         in the timelock==0 path don't need two separate calls.
    function awaitAndExecute(PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        external
        payable
        returns (uint64 nonce, bytes32 opId);

    /// @notice Cancel a pending batch. Any manager of `poolId` may call this.
    /// @param poolId   The pool the batch was awaited against.
    /// @param nonce    The per-pool nonce assigned to the pending op.
    /// @param calls    The exact array passed to {await}.
    /// @param callback The exact callback passed to {await}.
    function cancel(PoolId poolId, uint64 nonce, bytes[] calldata calls, bytes calldata callback) external;

    /// @notice Called by the gateway during {execute} to replay a batch under the submitter's
    ///         identity. NOT to be called directly — protected by msg.sender + the gateway
    ///         callback lock.
    function executeBatch(bytes[] calldata calls) external payable;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Helper to construct holding accounts array
    /// @param assetAccount Account for tracking assets
    /// @param equityAccount Account for tracking equity
    /// @param gainAccount Account for tracking gains
    /// @param lossAccount Account for tracking losses
    /// @return accounts Array of holding accounts
    function holdingAccounts(
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) external pure returns (HoldingAccount[] memory accounts);

    /// @notice Helper to construct liability accounts array
    /// @param expenseAccount Account for tracking expenses
    /// @param liabilityAccount Account for tracking liabilities
    /// @return accounts Array of holding accounts
    function liabilityAccounts(AccountId expenseAccount, AccountId liabilityAccount)
        external
        pure
        returns (HoldingAccount[] memory accounts);

    /// @notice Get the price per asset for a holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return The price in pool units per asset unit
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18);
}

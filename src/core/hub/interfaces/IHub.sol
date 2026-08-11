// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHoldings} from "./IHoldings.sol";
import {IValuation} from "./IValuation.sol";
import {IFeeAccrual} from "./IFeeAccrual.sol";
import {IHubRegistry} from "./IHubRegistry.sol";
import {ISnapshotHook} from "./ISnapshotHook.sol";
import {IAccounting, JournalEntry} from "./IAccounting.sol";
import {IHubRequestManager} from "./IHubRequestManager.sol";
import {IShareClassManager} from "./IShareClassManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {IAdapter} from "../../messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../messaging/interfaces/IMultiAdapter.sol";
import {IHubMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";
import {VaultUpdateKind, ManagerKind} from "../../messaging/libraries/MessageLib.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IHubPolicy} from "../../utils/interfaces/IPolicy.sol";
import {IBatchedMulticall} from "../../utils/interfaces/IBatchedMulticall.sol";

/// @notice Account slots a settlement event posts against. The pool assigns an AccountId to each slot
///         at initializeHolding; core has no opinion on their accounting meaning.
/// @dev There are exactly four slots by design. Holdings with different accounting semantics (an asset
///      vs a liability, say) are distinguished by which account is assigned to each slot, not by adding
///      more slots: a liability is a holding whose counterpart slots point at a liability-normal account.
/// @dev Migration note: v3.1.0 used AccountType {Asset, Equity, Loss=2, Gain=3, Expense, Liability}. The slot
///      ordinals differ, so the migration spell must map AccountType.Loss (2) -> AccountKind.ValueDecrease (3)
///      and AccountType.Gain (3) -> AccountKind.ValueIncrease (2) when repointing existing holding accounts.
enum AccountKind {
    AmountDebit, // the holding's own account (asset/expense side)
    AmountCredit, // amount-change counterpart (equity/liability side)
    ValueIncrease, // revaluation-increase counterpart (gain side)
    ValueDecrease // revaluation-decrease counterpart (loss side)
}

/// @notice Interface with all methods available in the system used by actors
interface IHub is IBatchedMulticall {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event NotifyPool(uint16 indexed centrifugeId, PoolId indexed poolId);
    event NotifyShareClass(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes payload);
    event NotifyShareMetadata(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, string name, string symbol
    );
    event NotifySharePrice(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, D18 poolPerShare, uint64 computedAt
    );
    event NotifyAssetPrice(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset
    );
    event UpdateRestriction(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes payload);
    event SetSpokeRequestManager(uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 indexed manager);
    event SetSpokePolicy(uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 indexed policy);
    event AuthorizeSpokeCall(uint16 indexed centrifugeId, PoolId indexed poolId, bytes data);
    event UnauthorizeSpokeCall(uint16 indexed centrifugeId, PoolId indexed poolId, bytes data);
    event UpdateManager(
        uint16 indexed centrifugeId, PoolId indexed poolId, ManagerKind kind, bytes32 indexed who, bool canManage
    );
    event UpdateVault(
        PoolId indexed poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        bytes payload
    );
    event ManagerCall(uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 target, bytes payload);
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

    /// @notice Dispatched when the pool is already unlocked.
    ///         It means when calling to `execute()` inside `execute()`.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the pool can not be unlocked by the caller
    error NotManager();

    /// @notice Dispatched when an invalid centrifuge ID is set in the pool ID.
    error InvalidPoolId();

    error InvalidRequestManager();

    error RequestManagerCallFailed();

    /// @notice Dispatched when `localValue` is inconsistent with `centrifugeId`: local target requires
    ///         `localValue == msgValue()`; remote target requires `localValue == 0`.
    error ManagerCallUnexpectedValue();

    /// @notice Dispatched when setAdapters is called while the gateway is batching. SetPoolAdapters must be
    ///         transmitted over the adapter set still shared with the destination, which requires the message
    ///         to be sent before the new local set is applied. Batching defers the send until after the local
    ///         set has changed, so it would route over a set the destination does not have yet.
    error CannotSetAdaptersWhileBatching();

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

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

    /// @notice Module that accrues protocol fees on NAV updates
    function feeAccrual() external view returns (IFeeAccrual);

    /// @notice Handles multi-protocol message verification and routing for cross-chain communication
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice Returns the policy installed for a pool (address(0) if none),
    ///         consulted on every manager call. Storage lives in the {IHubRegistry}; this reads through.
    function policy(PoolId poolId) external view returns (IHubPolicy);

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update (accepts 'gateway', 'feeAccrual', 'sender', 'multiAdapter')
    /// @param data Address of the new contract
    function file(bytes32 what, address data) external;

    /// @notice Install or replace the policy for a pool.
    /// @dev    Wards may call directly (break-glass). For managers the current policy is enforced,
    ///         which typically requires an authorization for its own replacement.
    function setPolicy(PoolId poolId, IHubPolicy policy_) external;

    /// @notice Pre-authorize a future, out-of-policy call against the Hub's timelock ledger. Manager only.
    /// @param poolId The pool the call targets
    /// @param data The exact future calldata being authorized
    function initiateAuthorization(PoolId poolId, bytes calldata data) external;

    /// @notice Cancel a pending authorization. Manager only. Sentinels act through their pool's Supervisor.
    /// @param poolId The pool the authorization targets
    /// @param data The exact calldata that was authorized
    function cancelAuthorization(PoolId poolId, bytes calldata data) external;

    //----------------------------------------------------------------------------------------------
    // Manager: Pool configuration
    //----------------------------------------------------------------------------------------------

    /// @notice Set adapters for a pool in another chain.
    /// @dev    Installing a new set does NOT invalidate the previous ones. Each call increments the pool's session
    ///         ID on both endpoints: outgoing messages always travel over the newest session, but every earlier
    ///         session stays valid for incoming messages, and any of their adapters can still reach quorum and
    ///         deliver. That is deliberate: messages already in flight were wrapped with the session ID that was
    ///         active when they were sent, so keeping old sessions alive is what lets pending traffic reach the
    ///         destination instead of being dropped on every adapter rotation.
    ///
    ///         Retiring an old session is therefore a separate, receiver-side action: call
    ///         `multiAdapter.blockSession(centrifugeId, poolId, sessionId)` on the chain that would receive those
    ///         messages. This needs no protocol-level access — `updateManager()` with `ManagerKind.Adapter`
    ///         appoints a per-pool adapter manager on any chain, and that manager can block (and later unblock)
    ///         the pool's own sessions. NOTE: leaving retired sessions unblocked indefinitely is a security risk,
    ///         since a rotation away from a compromised set does not by itself stop that set from delivering
    ///         messages. Blocking is expected to lag a rotation only for as long as messages may still be in
    ///         flight, not to be skipped.
    ///
    ///         Recommended flow to retire an old adapter set/session without dropping messages:
    ///         1. Call setAdapters() with the new adapter set.
    ///         2. Wait until every message sent under the old session has been delivered.
    ///         3. Only then call blockSession() for the old session on the receiving chain, since blocking a
    ///            session that still has messages in flight would drop them. If it turns out to have been
    ///            retired too early, `unblockSession()` restores it.
    ///
    ///         This path only works while the pool's current adapters do: SetPoolAdapters routes over that very set,
    ///         so an adapter reverting on `estimate`/`send` blocks the rotation that would remove it. Recovering from
    ///         that requires rotating each endpoint locally, as described in {IMultiAdapter-setAdapters}.
    /// @param poolId Pool associated to this configuration
    /// @param centrifugeId Chain where to perform the adapter configuration
    /// @param localAdapters Adapter addresses in this chain
    /// @param remoteAdapters Adapter addresses in the remote chain
    /// @param threshold Minimum number of adapters required to process the messages
    /// @param refund Address to receive excess gas refund
    function setAdapters(
        PoolId poolId,
        uint16 centrifugeId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        address refund
    ) external payable;

    /// @notice Set or clear the bridging hook for a pool
    /// @param poolId The pool identifier
    /// @param hook The hook contract address, or address(0) to clear
    function setBridgingHook(PoolId poolId, address hook) external;

    /// @notice Set snapshot hook for a pool
    /// @param poolId The pool identifier
    /// @param hook The snapshot hook contract
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable;

    /// @notice Attach custom data to a pool
    /// @param poolId The pool identifier
    /// @param metadata Custom metadata to attach
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable;

    /// @notice Update the pool's currency
    /// @dev The new currency MUST have the same decimals as the current one: pool decimals are baked into
    ///      already-deployed share tokens (immutable), so they cannot change. Reverts otherwise.
    /// @param poolId The pool identifier
    /// @param currency The new pool currency asset
    function updateCurrency(PoolId poolId, AssetId currency) external;

    /// @notice Update name & symbol of share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param name New name for the share class
    /// @param symbol New symbol for the share class
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable;

    //----------------------------------------------------------------------------------------------
    // Manager: Permissions & routing
    //----------------------------------------------------------------------------------------------

    /// @notice Allow/disallow an account to interact as hub manager for this pool
    /// @param poolId The pool identifier
    /// @param who Address to update manager status for
    /// @param canManage Whether the address can manage the pool
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable;

    /// @notice Allow/disallow an account to interact as a manager for the given target contract.
    /// @dev A message is sent to (or executed on) `centrifugeId`.
    ///      When `kind == Gateway`, see {IGateway.updateManager} for the security implications:
    ///      a gateway manager can inject arbitrary hub-originated messages for the pool.
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain where the manager will operate
    /// @param kind Which contract's manager mapping is updated (Adapter, Gateway, Spoke, Bridger)
    /// @param who Address to update manager status for
    /// @param canManage Whether the address can manage the target
    /// @param refund Address to receive excess gas refund
    function updateManager(
        PoolId poolId,
        uint16 centrifugeId,
        ManagerKind kind,
        bytes32 who,
        bool canManage,
        address refund
    ) external payable;

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

    /// @notice Install or replace the policy enforced on a spoke pool's balance-sheet manager methods
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain of the spoke whose policy is set
    /// @param policy_ The spoke-chain policy contract (address(0) to remove policy enforcement)
    /// @param refund Address to receive excess gas refund
    function setSpokePolicy(PoolId poolId, uint16 centrifugeId, bytes32 policy_, address refund) external payable;

    /// @notice Authorize an out-of-policy call on a spoke pool. Manager-gated and classified as a std delay
    ///         by the Hub-side policy, so it matures through the Hub timelock and sentinel veto before pushing
    ///         the authorization to the spoke for a manager to consume. Only the Hub chain needs a cold wallet.
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain of the spoke the authorized call targets
    /// @param data The exact spoke calldata being authorized
    /// @param refund Address to receive excess gas refund
    function authorizeSpokeCall(PoolId poolId, uint16 centrifugeId, bytes calldata data, address refund)
        external
        payable;

    /// @notice Revoke a previously-authorized, not-yet-consumed spoke call. Manager-gated and immediate (no
    ///         timelock): it only reduces capability, letting a manager retire a stale authorization.
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain of the spoke the authorized call targets
    /// @param data The exact spoke calldata whose authorization is revoked
    /// @param refund Address to receive excess gas refund
    function unauthorizeSpokeCall(PoolId poolId, uint16 centrifugeId, bytes calldata data, address refund)
        external
        payable;

    //----------------------------------------------------------------------------------------------
    // Manager: Share classes & vaults
    //----------------------------------------------------------------------------------------------

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
    /// @param payload Opaque data forwarded to the factory on DeployAndLink; empty otherwise. A larger payload
    ///                costs more calldata/memory on the spoke, so size `extraGasLimit` accordingly.
    /// @param extraGasLimit Extra gas limit for remote computation
    /// @param refund Address to receive excess gas refund
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    //----------------------------------------------------------------------------------------------
    // Manager: Holdings & accounting
    //----------------------------------------------------------------------------------------------

    /// @notice Update the price per share of a share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param pricePoolPerShare The new price per share
    /// @param computedAt Timestamp when the price was computed (must be <= block.timestamp)
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt)
        external
        payable;

    /// @notice Convenience overload that calls updateSharePrice with computedAt = block.timestamp.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param pricePoolPerShare The new price per share
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external payable;

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

    /// @notice Create a new holding associated to the asset in a share class.
    ///         It registers the accounts posted against for each settlement slot ({AccountKind}).
    ///         The accounts have to be created beforehand.
    ///         The same account can be used for different kinds.
    ///         e.g.: The AmountCredit, ValueIncrease, and ValueDecrease account can be the same account.
    ///         They can also be shared across assets.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation Used to transform between payment assets and pool currency
    /// @param accounts The accounts assigned to each settlement slot (indexed by {AccountKind})
    function initializeHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId[4] calldata accounts
    ) external payable;

    /// @notice Updates the pool currency value of this holding based of the associated valuation
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

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

    /// @notice Perform an accounting entries update
    /// @param poolId The pool identifier
    /// @param debits Array of debit journal entries
    /// @param credits Array of credit journal entries
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external payable;

    //----------------------------------------------------------------------------------------------
    // Manager: Spoke notifications
    //----------------------------------------------------------------------------------------------

    /// @notice Notify to a CV instance that a new pool is available
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param refund Address to receive excess gas refund
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable;

    /// @notice Notify to a CV instance that a new share class is available
    /// @dev    Unlike its sibling notifications this does not re-push committed state: `registrar` and
    ///         `payload` are caller-supplied, and the registrar becomes the share token's mint authority on
    ///         the target chain. The standard Hub policy therefore classifies it out of policy.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param registrar The registrar (on the target chain) that deploys and operates the share token
    /// @param payload Opaque data forwarded verbatim to the registrar's `newToken`; empty if unused
    /// @param extraGasLimit Extra gas for the registrar's `newToken` deployment on the destination chain
    /// @param refund Address to receive excess gas refund
    function notifyShareClass(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 registrar,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Notify to a CV instance that share metadata has updated
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId Chain where CV instance lives
    /// @param extraGasLimit Extra gas for the registrar's `updateMetadata` call on the destination chain
    /// @param refund Address to receive excess gas refund
    function notifyShareMetadata(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        uint128 extraGasLimit,
        address refund
    ) external payable;

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

    //----------------------------------------------------------------------------------------------
    // Manager: Envoy calls
    //----------------------------------------------------------------------------------------------

    /// @notice Route a payable, supervised manager call to an `IManagerCallFromHub` target via the `Envoy`.
    ///         Pool-scoped: any `scId` is encoded in `payload`. No origin args reach the target: the call
    ///         is already authorized here via `_enforce` + policy.
    /// @param poolId The pool identifier
    /// @param centrifugeId Chain where the target lives (only the local chain is currently supported)
    /// @param target Contract to call (as bytes32; converted to address for local dispatch)
    /// @param payload Opaque bytes decoded by the target's `fromHub`
    /// @param extraGasLimit Extra gas for remote computation. Inert on the local branch; carried for
    ///        forward compatibility so wiring the cross-chain branch needs no Hub redeploy.
    /// @param localValue Native value forwarded to the target. Only valid for local targets; must be 0 for remote.
    /// @param refund Address to receive any refunded remainder
    function managerCall(
        PoolId poolId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        uint256 localValue,
        address refund
    ) external payable;

    //----------------------------------------------------------------------------------------------
    // Accounting methods
    //----------------------------------------------------------------------------------------------

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
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Get the price per asset for a holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return The price in pool units per asset unit
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18);
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "./IValuation.sol";
import {IHubRegistry} from "./IHubRegistry.sol";
import {ISnapshotHook} from "./ISnapshotHook.sol";
import {IHoldings, HoldingAccount} from "./IHoldings.sol";
import {IAccounting, JournalEntry} from "./IAccounting.sol";
import {IHubRequestManager} from "./IHubRequestManager.sol";
import {IShareClassManager} from "./IShareClassManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {VaultUpdateKind} from "../../messaging/libraries/MessageLib.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {IAdapter} from "../../interfaces/IAdapter.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IHubMessageSender} from "../../interfaces/IGatewaySenders.sol";
import {IBatchedMulticall} from "../../interfaces/IBatchedMulticall.sol";

/// @notice Account types used by Hub
enum AccountType {
    /// @notice Debit normal account for tracking assets
    Asset,
    /// @notice Credit normal account for tracking equities
    Equity,
    /// @notice Credit normal account for tracking losses
    Loss,
    /// @notice Credit normal account for tracking profits
    Gain,
    /// @notice Debit normal account for tracking expenses
    Expense,
    /// @notice Credit normal account for tracking liabilities
    Liability
}

/// @notice Interface with all methods available in the system used by actors
interface IHub is IBatchedMulticall {
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
    event UpdateVault(
        PoolId indexed poolId, ShareClassId scId, AssetId assetId, bytes32 vaultOrFactory, VaultUpdateKind kind
    );
    event UpdateContract(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 target, bytes payload
    );
    event SetMaxAssetPriceAge(PoolId indexed poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge);
    event SetMaxSharePriceAge(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, uint64 maxPriceAge
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

    /// @notice Dispatched when the pool is already unlocked.
    ///         It means when calling to `execute()` inside `execute()`.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the pool can not be unlocked by the caller
    error NotManager();

    /// @notice Dispatched when an invalid centrifuge ID is set in the pool ID.
    error InvalidPoolId();

    /// @notice Dispatched when an invalid combination of account IDs is passed.
    error InvalidAccountCombination();

    error InvalidRequestManager();

    error RequestManagerCallFailed();

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
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund)
        external
        payable;

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

    /// @notice Set the max price age per asset of a share class
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param maxPriceAge Timestamp until the price become invalid
    /// @param refund Address to receive excess gas refund
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge, address refund)
        external
        payable;

    /// @notice Set the max price age per share of a share class
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param centrifugeId Chain where CV instance lives
    /// @param maxPriceAge Timestamp until the price become invalid
    /// @param refund Address to receive excess gas refund
    function setMaxSharePriceAge(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        uint64 maxPriceAge,
        address refund
    ) external payable;

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
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits)
        external
        payable;

    /// @notice Set adapters for a pool in another chain
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

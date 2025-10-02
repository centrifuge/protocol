// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHubRegistry} from "./IHubRegistry.sol";
import {IHoldings, HoldingAccount} from "./IHoldings.sol";
import {IAccounting, JournalEntry} from "./IAccounting.sol";
import {IHubRequestManager} from "./IHubRequestManager.sol";
import {IShareClassManager} from "./IShareClassManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {VaultUpdateKind} from "../../../messaging/libraries/MessageLib.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {IAdapter} from "../../interfaces/IAdapter.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IValuation} from "../../interfaces/IValuation.sol";
import {ISnapshotHook} from "../../interfaces/ISnapshotHook.sol";
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
    event NotifyPool(uint16 indexed centrifugeId, PoolId indexed poolId);
    event NotifyShareClass(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId);
    event NotifyShareMetadata(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, string name, string symbol
    );
    event UpdateShareHook(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 hook);
    event NotifySharePrice(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, D18 poolPerShare);
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

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Dispatched when the pool is already unlocked.
    /// It means when calling to `execute()` inside `execute()`.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the pool can not be unlocked by the caller
    error NotManager();

    /// @notice Dispatched when an invalid centrifuge ID is set in the pool ID.
    error InvalidPoolId();

    /// @notice Dispatched when an invalid combination of account IDs is passed.
    error InvalidAccountCombination();

    /// @notice TODO
    error InvalidRequestManager();

    /// @notice TODO
    error RequestManagerCallFailed();

    function holdings() external view returns (IHoldings);
    function accounting() external view returns (IAccounting);
    function hubRegistry() external view returns (IHubRegistry);
    function sender() external view returns (IHubMessageSender);
    function shareClassManager() external view returns (IShareClassManager);

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry', 'assetRegistry', 'accounting', 'holdings', 'gateway' and '
    /// sender' as string value.
    function file(bytes32 what, address data) external;

    /// @notice Notify to a CV instance that a new pool is available
    /// @param centrifugeId Chain where CV instance lives
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable;

    /// @notice Notify to a CV instance that a new share class is available
    /// @param centrifugeId Chain where CV instance lives
    /// @param hook The hook address of the share class
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable;

    /// @notice Notify to a CV instance that share metadata has updated
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund)
        external
        payable;

    /// @notice Update on a CV instance the hook of a share token
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / SHARE_UNIT
    /// @dev The receiving centrifugeId is derived from the provided assetId
    /// @param centrifugeId Chain to where the share price is notified
    /// @param scId Identifier of the share class
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / ASSET_UNIT
    /// @dev The receiving centrifugeId is derived from the provided assetId
    /// @param scId Identifier of the share class
    /// @param assetId Identifier of the asset
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId, address refund) external payable;

    /// @notice Set the max price age per asset of a share class
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  maxPriceAge timestamp until the price become invalid
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge, address refund)
        external
        payable;

    /// @notice Set the max price age per share of a share class
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  maxPriceAge timestamp until the price become invalid
    function setMaxSharePriceAge(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        uint64 maxPriceAge,
        address refund
    ) external payable;

    /// @notice Attach custom data to a pool
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable;

    /// @notice Set snapshot hook for a pool
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable;

    /// @notice Update name & symbol of share class
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable;

    /// @notice Allow/disallow an account to interact as hub manager this pool
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable;

    /// @notice Allow/disallow an account to interact as request manager
    function setRequestManager(
        PoolId poolId,
        uint16 centrifugeId,
        IHubRequestManager hubManager,
        bytes32 spokeManager,
        address refund
    ) external payable;

    /// @notice Allow/disallow an account to interact as balance sheet manager for this pool
    function updateBalanceSheetManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable;

    /// @notice Add a new share class to the pool
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId);

    /// @notice Update remotely a restriction.
    /// @param centrifugeId Chain where CV instance lives.
    /// @param payload content of the restriction update to execute.
    /// @param extraGasLimit extra gas limit used for some extra computation that can happen by some callback in the
    /// remote centrifugeId. Avoid this param if the message applies to the same centrifugeId.
    function updateRestriction(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Updates a vault based on VaultUpdateKind
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  vaultOrFactory The address of the vault or the factory, depending on the kind value
    /// @param  kind The kind of action applied
    /// @param extraGasLimit extra gas limit used for some extra computation that can happen by some callback in the
    /// remote centrifugeId. Avoid this param if the message applies to the same centrifugeId.
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Update remotely an existing vault.
    /// @param centrifugeId Chain where CV instance lives.
    /// @param target contract where to execute in CV. Check IUpdateContract interface.
    /// @param payload content of the update to execute.
    /// @param extraGasLimit extra gas limit used for some extra computation that can happen by some callback in the
    /// remote centrifugeId. Avoid this param if the message applies to the same centrifugeId.
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
    /// @param scId The share class identifier
    /// @param pricePoolPerShare The new price per share
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external payable;

    /// @notice Create a new holding associated to the asset in a share class.
    /// It will register the different accounts used for holdings.
    /// The accounts have to be created beforehand.
    /// The same account can be used for different kinds.
    /// e.g.: The equity, gain, and loss account can be the same account.
    /// They can also be shared across assets.
    /// e.g.: All assets can use the same equity account.
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

    /// @notice Create a new liablity associated to the asset in a share class.
    /// It will register the different accounts used for holdings.
    /// The accounts have to be created beforehand.
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

    /// @notice Updates the pool currency value of this holding based of the associated valuation.
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Updates whether the holding represents a liability or not.
    function updateHoldingIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability)
        external
        payable;

    /// @notice Updates the valuation used by a holding
    /// @param valuation Used to transform between the holding asset and pool currency
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable;

    /// @notice Set an account of a holding
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable;

    /// @notice Creates an account
    /// @param accountId Then new AccountId used
    /// @param isDebitNormal Determines if the account should be used as debit-normal or credit-normal
    function createAccount(PoolId poolId, AccountId accountId, bool isDebitNormal) external payable;

    /// @notice Attach custom data to an account
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable;

    /// @notice Perform an accounting entries update.
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits)
        external
        payable;

    /// @notice Set adapters for a pool in another chain. Pool related message will go by these adapters.
    ///         The adapters should already be deployed and wired.
    /// @param  poolId pool associated to this configuration.
    /// @param  centrifugeId chain where to perform the adapter configuration.
    /// @param  localAdapters Adapter addresses in this chain.
    /// @param  remoteAdapters Adapter addresses in the remote chain.
    /// @param  threshold Minimum number of adapters required to process the messages
    ///         If not wanted a threshold set `adapters.length` value
    /// @param  recoveryIndex Index in adapters array from where consider the adapter as recovery adapter.
    ///         If not wanted a recoveryIndex set `adapters.length` value
    function setAdapters(
        PoolId poolId,
        uint16 centrifugeId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        uint8 recoveryIndex,
        address refund
    ) external payable;

    /// @notice Update a gateway manager for a pool. The manager can modify gateway-related things in the remote chain.
    /// @param poolId pool associated to this configuration.
    /// @param centrifugeId chain where to perform the gateway configuration.
    /// @param who address used as manager.
    /// @param canManage if enabled as manager
    function updateGatewayManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable;

    /// @notice Calls the request manager for a specific pool and centrifuge chain
    /// @dev This is included in the Hub contract in order to be included in multicalls with other Hub methods.
    /// @param poolId The pool ID
    /// @param centrifugeId The centrifuge chain ID
    /// @param data The encoded function call data
    function callRequestManager(PoolId poolId, uint16 centrifugeId, bytes calldata data) external payable;

    function updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        payable;

    function updateAccountingValue(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        payable;

    function holdingAccounts(
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) external pure returns (HoldingAccount[] memory accounts);

    function liabilityAccounts(AccountId expenseAccount, AccountId liabilityAccount)
        external
        pure
        returns (HoldingAccount[] memory accounts);

    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18);
}

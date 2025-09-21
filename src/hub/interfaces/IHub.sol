// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHoldings} from "./IHoldings.sol";
import {IHubRegistry} from "./IHubRegistry.sol";
import {IAccounting, JournalEntry} from "./IAccounting.sol";
import {IShareClassManager} from "./IShareClassManager.sol";

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {AccountId} from "../../common/types/AccountId.sol";
import {IAdapter} from "../../common/interfaces/IAdapter.sol";
import {IGateway} from "../../common/interfaces/IGateway.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {IValuation} from "../../common/interfaces/IValuation.sol";
import {VaultUpdateKind} from "../../common/libraries/MessageLib.sol";
import {ISnapshotHook} from "../../common/interfaces/ISnapshotHook.sol";
import {IHubMessageSender} from "../../common/interfaces/IGatewaySenders.sol";

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
interface IHub {
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
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 receiver, uint128 amount
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

    function gateway() external view returns (IGateway);
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

    /// @notice Notify a deposit for an investor address located in the chain where the asset belongs
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId depositAssetId, bytes32 investor, uint32 maxClaims)
        external
        returns (uint256 cost);

    /// @notice Notify a redemption for an investor address located in the chain where the asset belongs
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, bytes32 investor, uint32 maxClaims)
        external
        returns (uint256 cost);

    /// @notice Notify to a CV instance that a new pool is available
    /// @param centrifugeId Chain where CV instance lives
    function notifyPool(PoolId poolId, uint16 centrifugeId) external returns (uint256 cost);

    /// @notice Notify to a CV instance that a new share class is available
    /// @param centrifugeId Chain where CV instance lives
    /// @param hook The hook address of the share class
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook)
        external
        returns (uint256 cost);

    /// @notice Notify to a CV instance that share metadata has updated
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId)
        external
        returns (uint256 cost);

    /// @notice Update on a CV instance the hook of a share token
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook)
        external
        returns (uint256 cost);

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / SHARE_UNIT
    /// @dev The receiving centrifugeId is derived from the provided assetId
    /// @param centrifugeId Chain to where the share price is notified
    /// @param scId Identifier of the share class
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external returns (uint256 cost);

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / ASSET_UNIT
    /// @dev The receiving centrifugeId is derived from the provided assetId
    /// @param scId Identifier of the share class
    /// @param assetId Identifier of the asset
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId) external returns (uint256 cost);

    /// @notice Set the max price age per asset of a share class
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  maxPriceAge timestamp until the price become invalid
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge)
        external
        returns (uint256 cost);

    /// @notice Set the max price age per share of a share class
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  maxPriceAge timestamp until the price become invalid
    function setMaxSharePriceAge(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint64 maxPriceAge)
        external
        returns (uint256 cost);

    /// @notice Attach custom data to a pool
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external;

    /// @notice Set snapshot hook for a pool
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external;

    /// @notice Update name & symbol of share class
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external;

    /// @notice Allow/disallow an account to interact as hub manager this pool
    function updateHubManager(PoolId poolId, address who, bool canManage) external;

    /// @notice Allow/disallow an account to interact as request manager
    function setRequestManager(PoolId poolId, uint16 centrifugeId, address hubManager, bytes32 spokeManager)
        external
        returns (uint256 cost);

    /// @notice Allow/disallow an account to interact as balance sheet manager for this pool
    function updateBalanceSheetManager(uint16 centrifugeId, PoolId poolId, bytes32 who, bool canManage)
        external
        returns (uint256 cost);

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
        uint128 extraGasLimit
    ) external returns (uint256 cost);

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
        uint128 extraGasLimit
    ) external returns (uint256 cost);

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
        uint128 extraGasLimit
    ) external returns (uint256 cost);

    /// @notice Update the price per share of a share class
    /// @param scId The share class identifier
    /// @param pricePoolPerShare The new price per share
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external;

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
    ) external;

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
    ) external;

    /// @notice Updates the pool currency value of this holding based of the associated valuation.
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external;

    /// @notice Updates whether the holding represents a liability or not.
    function updateHoldingIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability) external;

    /// @notice Updates the valuation used by a holding
    /// @param valuation Used to transform between the holding asset and pool currency
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation) external;

    /// @notice Set an account of a holding
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external;

    /// @notice Creates an account
    /// @param accountId Then new AccountId used
    /// @param isDebitNormal Determines if the account should be used as debit-normal or credit-normal
    function createAccount(PoolId poolId, AccountId accountId, bool isDebitNormal) external;

    /// @notice Attach custom data to an account
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external;

    /// @notice Perform an accounting entries update.
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external;

    /// @notice Set adapters for a pool in another chain. Pool related message will go by these adapters.
    ///         The adapters should already be deployed and wired.
    /// @param  centrifugeId chain where to perform the adapter configuration.
    /// @param  poolId pool associated to this configuration.
    /// @param  localAdapters Adapter addresses in this chain.
    /// @param  remoteAdapters Adapter addresses in the remote chain.
    /// @param  threshold Minimum number of adapters required to process the messages
    ///         If not wanted a threshold set `adapters.length` value
    /// @param  recoveryIndex Index in adapters array from where consider the adapter as recovery adapter.
    ///         If not wanted a recoveryIndex set `adapters.length` value
    function setAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external returns (uint256 cost);

    /// @notice Set a gateway manager for a pool. The manager can modify gateway-related things in the remote chain.
    /// @param centrifugeId chain where to perform the gateway configuration.
    /// @param poolId pool associated to this configuration.
    /// @param manager address used as manager.
    function setGatewayManager(uint16 centrifugeId, PoolId poolId, bytes32 manager) external returns (uint256 cost);

    /// @notice Calls the request manager for a specific pool and centrifuge chain
    /// @dev This is included in the Hub contract in order to be included in multicalls with other Hub methods.
    /// @param poolId The pool ID
    /// @param centrifugeId The centrifuge chain ID
    /// @param data The encoded function call data
    /// @return cost The gas cost for the operation
    function callRequestManager(PoolId poolId, uint16 centrifugeId, bytes calldata data)
        external
        returns (uint256 cost);
}

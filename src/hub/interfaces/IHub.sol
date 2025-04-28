// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";

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
    event NotifySharePrice(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, string name, string symbol
    );
    event UpdateShareHook(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 hook);
    event NotifySharePrice(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, D18 poolPerShare);
    event NotifyAssetPrice(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset
    );
    event UpdateRestriction(uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes payload);
    event UpdateContract(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId scId, bytes32 target, bytes payload
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

    function gateway() external view returns (IGateway);
    function holdings() external view returns (IHoldings);
    function accounting() external view returns (IAccounting);
    function hubRegistry() external view returns (IHubRegistry);
    function sender() external view returns (IPoolMessageSender);
    function shareClassManager() external view returns (IShareClassManager);

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry', 'assetRegistry', 'accounting', 'holdings', 'gateway' and '
    /// sender' as string value.
    function file(bytes32 what, address data) external;

    /// @notice Creates a new pool. `msg.sender` will be the admin of the created pool.
    /// @param currency The pool currency. Usually an AssetId identifying by a ISO4217 code.
    function createPool(PoolId poolId, address admin, AssetId currency) external payable;

    /// @notice Notify a deposit for an investor address located in the chain where the asset belongs
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId depositAssetId, bytes32 investor, uint32 maxClaims)
        external
        payable;

    /// @notice Notify a redemption for an investor address located in the chain where the asset belongs
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, bytes32 investor, uint32 maxClaims)
        external
        payable;

    /// @notice Notify to a CV instance that a new pool is available
    /// @param centrifugeId Chain where CV instance lives
    function notifyPool(PoolId poolId, uint16 centrifugeId) external payable;

    /// @notice Notify to a CV instance that a new share class is available
    /// @param centrifugeId Chain where CV instance lives
    /// @param hook The hook address of the share class
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook) external payable;

    /// @notice Notify to a CV instance that share metadata has updated
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external payable;

    /// @notice Update on a CV instance the hook of a share token
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / SHARE_UNIT
    /// @dev The receiving centrifugeId is derived from the provided assetId
    /// @param centrifugeId Chain to where the share price is notified
    /// @param scId Identifier of the share class
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / ASSET_UNIT
    /// @dev The receiving centrifugeId is derived from the provided assetId
    /// @param scId Identifier of the share class
    /// @param assetId Identifier of the asset
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Attach custom data to a pool
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable;

    /// @notice Update name & symbol of share class
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable;

    /// @notice Allow/disallow an account to interact as pool manager
    function updateManager(PoolId poolId, address who, bool canManage) external payable;

    /// @notice Add a new share class to the pool
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        payable;

    /// @notice Approves an asset amount of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param scId Identifier of the share class
    /// @param depositAssetId Identifier of the asset locked for the deposit request
    /// @param nowDepositEpochId The epoch for which deposits will be approved.
    /// @param approvedAssetAmount Ampunt of assets that will be approved
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount
    ) external payable returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount);

    /// @notice Approves a percentage of all redemption requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param nowRedeemEpochId The epoch for which redemptions will be approved.
    /// @param approvedShareAmount Amount of shares that will be approved
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount
    ) external payable returns (uint128 pendingShareAmount);

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param nowIssueEpochId The epoch for which shares will be issued.
    /// @param navPoolPerShare Total value of assets of the share class per share
    function issueShares(
        PoolId poolId,
        ShareClassId id,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare
    ) external payable returns (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount);

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    /// deposit asset id.
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param nowRevokeEpochId The epoch for which shares will be issued.
    /// @param navPoolPerShare Total value of assets of the share class per share
    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare
    ) external payable returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount);

    /// @notice Tells the BalanceSheet to issue/revoke shares.
    function triggerIssueShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, address who, uint128 shares)
        external
        payable;

    /// @notice Tell the BalanceSheet to send a message back with the queued issued/revoked shares.
    function triggerSubmitQueuedShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId) external payable;

    /// @notice  Tell the BalanceSheet to send a message back with the queued deposits/withdrawals.
    /// @param assetId Identifier of the asset which has queued deposits/withdrawals
    function triggerSubmitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Tell the BalanceSheet to enable or disable the shares queue.
    function setQueue(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bool enabled) external payable;

    /// @notice Update remotely a restriction.
    /// @param centrifugeId Chain where CV instance lives.
    /// @param payload content of the restriction update to execute.
    function updateRestriction(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes calldata payload)
        external
        payable;

    /// @notice Update remotely an existing vault.
    /// @param centrifugeId Chain where CV instance lives.
    /// @param target contract where to execute in CV. Check IUpdateContract interface.
    /// @param payload content of the update to execute.
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload
    ) external payable;

    /// @notice Update the price per share of a share class
    /// @param scId The share class identifier
    /// @param pricePoolPerShare The new price per share
    function updatePricePerShare(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external payable;

    /// @notice Create a new holding associated to the asset in a share class.
    /// It will register the different accounts used for holdings.
    /// The accounts have to be created beforehand.
    /// The same account can be used for different kinds.
    /// e.g.: The equity, loss, and gain account can be the same account.
    /// They can also be shared across assets.
    /// e.g.: All assets can use the same equity account.
    /// @param valuation Used to transform between payment assets and pool currency
    /// @param assetAccount Used to track the asset value
    /// @param equityAccount Used to track the equity value
    /// @param lossAccount Used to track the loss value
    /// @param gainAccount Used to track the gain value
    function createHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IERC7726 valuation,
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId lossAccount,
        AccountId gainAccount
    ) external payable;

    /// @notice Create a new liablity associated to the asset in a share class.
    /// It will register the different accounts used for holdings.
    /// The accounts have to be created beforehand.
    /// @param valuation Used to transform between the holding asset and pool currency
    /// @param expenseAccount Used to track the expense value
    /// @param liabilityAccount Used to track the liability value
    function createLiability(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IERC7726 valuation,
        AccountId expenseAccount,
        AccountId liabilityAccount
    ) external payable;

    /// @notice Updates the pool currency value of this holding based of the associated valuation.
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Updates the valuation used by a holding
    /// @param valuation Used to transform between the holding asset and pool currency
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation)
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
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external;
}

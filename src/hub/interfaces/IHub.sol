// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";

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
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    /// @notice Dispatched when the pool is already unlocked.
    /// It means when calling to `execute()` inside `execute()`.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the pool can not be unlocked by the caller
    error NotAuthorizedAdmin();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry', 'assetRegistry', 'accounting', 'holdings', 'gateway' and '
    /// sender' as string value.
    function file(bytes32 what, address data) external;

    /// @notice Creates a new pool. `msg.sender` will be the admin of the created pool.
    /// @param currency The pool currency. Usually an AssetId identifying by a ISO4217 code.
    /// @return PoolId The id of the new pool.
    function createPool(address admin, AssetId currency) external payable returns (PoolId);

    /// @notice Claim a deposit for an investor address located in the chain where the asset belongs
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable;

    /// @notice Claim a redemption for an investor address located in the chain where the asset belongs
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable;

    /// @notice Notify to a CV instance that a new pool is available
    /// @param centrifugeId Chain where CV instance lives
    function notifyPool(PoolId poolId, uint16 centrifugeId) external payable;

    /// @notice Notify to a CV instance that a new share class is available
    /// @param centrifugeId Chain where CV instance lives
    /// @param hook The hook address of the share class
    function notifyShareClass(PoolId poolId, uint16 centrifugeId, ShareClassId scId, bytes32 hook) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / SHARE_UNIT
    /// @dev The receiving chainId is derived from the provided assetId
    /// @param chainId Chain to where the share price is notified
    /// @param scId Identifier of the share class
    function notifySharePrice(PoolId poolId, uint16 chainId, ShareClassId scId) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / ASSET_UNIT
    /// @dev The receiving chainId is derived from the provided assetId
    /// @param scId Identifier of the share class
    /// @param assetId Identifier of the asset
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Attach custom data to a pool
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable;

    /// @notice Allow/disallow an account to interact as pool admin
    function allowPoolAdmin(PoolId poolId, address account, bool allow) external payable;

    /// @notice Add a new share class to the pool
    function addShareClass(
        PoolId poolId,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        bytes calldata data
    ) external payable;

    /// @notice Approves an asset amount of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param scId Identifier of the share class
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param maxApproval Sum of deposit request amounts in asset amount which is desired to be approved
    /// @param valuation Used to transform between payment assets and pool currency
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId paymentAssetId,
        uint128 maxApproval,
        IERC7726 valuation
    ) external payable;

    /// @notice Approves a percentage of all redemption requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param maxApproval Sum of redeem request amounts in share class token amount which is desired to be approved
    function approveRedeems(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval)
        external
        payable;

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param navPerShare Total value of assets of the share class per share
    function issueShares(PoolId poolId, ShareClassId id, AssetId depositAssetId, D18 navPerShare) external payable;

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    /// deposit asset id.
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param navPerShare Total value of assets of the share class per share
    /// @param valuation Used to transform between payout assets and pool currency
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        payable;

    /// @notice Update remotely a restriction.
    /// @param centrifugeId Chain where CV instance lives.
    /// @param payload content of the restriction update to execute.
    function updateRestriction(PoolId poolId, uint16 centrifugeId, ShareClassId scId, bytes calldata payload)
        external
        payable;

    /// @notice Update remotely an existing vault.
    /// @param centrifugeId Chain where CV instance lives.
    /// @param target contract where to execute in CV. Check IUpdateContract interface.
    /// @param payload content of the update to execute.
    function updateContract(
        PoolId poolId,
        uint16 centrifugeId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external payable;

    /// @notice Update the price per share of a share class
    /// @dev the provide price does not need to be the final price of the share class. This price can be retrieved via
    /// the IShareClassManager.shareClassPrice() method
    /// @param scId The share class identifier
    /// @param pricePerShare The new price per share
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 pricePerShare, bytes calldata data)
        external
        payable;

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

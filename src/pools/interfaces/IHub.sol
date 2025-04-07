// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

/// @notice AssetRegistry accounts identifications used by the Hub
enum EscrowId {
    /// @notice Represents the escrow for undeployed capital in the share class.
    /// Contains the already invested but not yet approved funds.
    PendingShareClass,
    /// @notice Represents the escrow for deployed capital in the share class.
    /// Contains the already invested and approved funds.
    ShareClass
}

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

    /// @notice Dispatched when the pool is not unlocked to interact with.
    error PoolLocked();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'poolRegistry', 'assetRegistry', 'accounting', 'holdings', 'gateway' and '
    /// sender' as string value.
    function file(bytes32 what, address data) external;

    /// @notice Main method to unlock the pool and call the rest of the admin methods
    function execute(PoolId poolId, bytes[] calldata data) external payable;

    /// @notice Creates a new pool. `msg.sender` will be the admin of the created pool.
    /// @param currency The pool currency. Usually an AssetId identifying by a ISO4217 code.
    /// @param shareClassManager The share class manager used for this pool.
    /// @return PoolId The id of the new pool.
    function createPool(address admin, AssetId currency, IShareClassManager shareClassManager)
        external
        payable
        returns (PoolId);

    /// @notice Claim a deposit for an investor address located in the chain where the asset belongs
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable;

    /// @notice Claim a redemption for an investor address located in the chain where the asset belongs
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable;

    /// @notice Sets a temporary the price of an asset in the pool currency
    /// @dev This price is set reflexive for both from asset to pool currency and from pool currency to asset
    /// @param assetId The asset identifier
    /// @param price The price of the asset
    function setTransientPrice(AssetId assetId, D18 price) external payable;

    /// @notice Notify to a CV instance that a new pool is available
    /// @param chainId Chain where CV instance lives
    function notifyPool(uint16 chainId) external payable;

    /// @notice Notify to a CV instance that a new share class is available
    /// @param chainId Chain where CV instance lives
    /// @param hook The hook address of the share class
    function notifyShareClass(uint16 chainId, ShareClassId scId, bytes32 hook) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / SHARE_UNIT
    /// @dev The receiving chainId is derived from the provided assetId
    /// @param chainId Chain to where the share price is notified
    /// @param scId Identifier of the share class
    function notifySharePrice(uint16 chainId, ShareClassId scId) external payable;

    /// @notice Notify to a CV instance the latest available price in POOL_UNIT / ASSET_UNIT
    /// @dev The receiving chainId is derived from the provided assetId
    /// @param scId Identifier of the share class
    /// @param assetId Identifier of the asset
    function notifyAssetPrice(ShareClassId scId, AssetId assetId) external payable;

    /// @notice Attach custom data to a pool
    function setPoolMetadata(bytes calldata metadata) external payable;

    /// @notice Allow/disallow an account to interact as pool admin
    function allowPoolAdmin(address account, bool allow) external payable;

    /// @notice Add a new share class to the pool
    function addShareClass(string calldata name, string calldata symbol, bytes32 salt, bytes calldata data)
        external
        payable;

    /// @notice Approves an asset amount of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param scId Identifier of the share class
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param maxApproval Sum of deposit request amounts in asset amount which is desired to be approved
    /// @param valuation Used to transform between payment assets and pool currency
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation)
        external
        payable;

    /// @notice Approves a percentage of all redemption requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param scId Identifier of the share class
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param maxApproval Sum of redeem request amounts in share class token amount which is desired to be approved
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) external payable;

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param navPerShare Total value of assets of the share class per share
    function issueShares(ShareClassId id, AssetId depositAssetId, D18 navPerShare) external payable;

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    /// deposit asset id.
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param navPerShare Total value of assets of the share class per share
    /// @param valuation Used to transform between payout assets and pool currency
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        payable;

    /// @notice Update remotely a restriction.
    /// @param chainId Chain where CV instance lives.
    /// @param payload content of the restriction update to execute.
    function updateRestriction(uint16 chainId, ShareClassId scId, bytes calldata payload) external payable;

    /// @notice Update remotely an existing vault.
    /// @param chainId Chain where CV instance lives.
    /// @param target contract where to execute in CV. Check IUpdateContract interface.
    /// @param payload content of the update to execute.
    function updateContract(uint16 chainId, ShareClassId scId, bytes32 target, bytes calldata payload)
        external
        payable;

    /// @notice Deploy a vault in the Vaults side.
    /// @param assetId Asset used in the vault.
    /// @param target contract where to execute this action in CV. Check IUpdateContract interface.
    /// @param vaultOrFactory Vault or Factory address, depending on kind. Check `IVaultFactory` interface.
    /// @param kind The action to do with the vault. See `VaultUpdateKind`
    function updateVault(
        ShareClassId scId,
        AssetId assetId,
        bytes32 target,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind
    ) external payable;

    /// @notice Update the price per share of a share class
    /// @dev the provide price does not need to be the final price of the share class. This price can be retrieved via
    /// the IShareClassManager.shareClassPrice() method
    /// @param scId The share class identifier
    /// @param pricePerShare The new price per share
    function updateSharePrice(ShareClassId scId, D18 pricePerShare, bytes calldata data) external payable;

    /// @notice Create a new holding associated to the asset in a share class.
    /// It will generate and register the different accounts used for holdings.
    /// @param valuation Used to transform between payment assets and pool currency
    /// @param isLiability Determines if the holding is a liability or not
    /// @param prefix Account prefix used for generating the account ids
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, bool isLiability, uint24 prefix)
        external
        payable;

    /// @notice Updates the pool currency value of this holding based of the associated valuation.
    function updateHolding(ShareClassId scId, AssetId assetId) external payable;

    /// @notice Updates the valuation used by a holding
    /// @param valuation Used to transform between payment assets and pool currency
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external payable;

    /// @notice Set an account of a holding
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external payable;

    /// @notice Creates an account
    /// @param accountId Then new AccountId used
    /// @param isDebitNormal Determines if the account should be used as debit-normal or credit-normal
    function createAccount(AccountId accountId, bool isDebitNormal) external payable;

    /// @notice Attach custom data to an account
    function setAccountMetadata(AccountId account, bytes calldata metadata) external payable;

    /// @notice Add debit an account. Increase the value of debit-normal accounts, decrease for credit-normal ones.
    function addDebit(AccountId account, uint128 amount) external payable;

    /// @notice Add credit an account. Decrease the value of debit-normal accounts, increase for credit-normal ones.
    function addCredit(AccountId account, uint128 amount) external payable;

    /// @notice Compute the escrow address used for a share class
    /// @return The escrow address
    function escrow(PoolId poolId, ShareClassId scId, EscrowId escrow_) external pure returns (address);

    /// @notice Return the share class manager for a pool
    function shareClassManager(PoolId poolId) external view returns (IShareClassManager);
}

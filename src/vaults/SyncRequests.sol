// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {d18, D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {JournalEntry, Meta} from "src/common/libraries/JournalEntryLib.sol";

import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IERC7540Redeem, IAsyncRedeemVault, IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {ISyncRequests, SyncPriceData} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncRequests is BaseInvestmentManager, ISyncRequests {
    using BytesLib for bytes;
    using MathLib for *;
    using CastLib for *;
    using MessageLib for *;

    IBalanceSheet public balanceSheet;

    mapping(uint64 poolId => mapping(bytes16 scId => mapping(uint128 assetId => address vault))) public vault;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => IERC7726))))
        public valuation;

    constructor(address root_, address escrow_) BaseInvestmentManager(root_, escrow_) {}

    // --- Administration ---
    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else revert("SyncRequests/file-unrecognized-param");
        emit File(what, data);
    }

    /// --- IUpdateContract ---
    /// @inheritdoc IUpdateContract
    function update(uint64 poolId, bytes16 scId, bytes memory payload) public auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.Valuation)) {
            MessageLib.UpdateContractValuation memory m = MessageLib.deserializeUpdateContractValuation(payload);

            require(poolManager.shareToken(poolId, scId) != address(0), "SyncRequests/share-token-does-not-exist");
            (address asset, uint256 tokenId) = poolManager.idToAsset(m.assetId);

            this.setValuation(m.poolId, m.scId, asset, tokenId, address(bytes20(m.valuation)));
        } else {
            revert("SyncRequests/unknown-update-contract-type");
        }
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        require(vault_.asset() == asset_, "SyncRequests/asset-mismatch");
        require(vault[poolId][scId][assetId] == address(0), "SyncRequests/vault-already-exists");

        address token = vault_.share();
        vault[poolId][scId][assetId] = vaultAddr;

        IAuth(token).rely(vaultAddr);
        IShareToken(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);

        (VaultKind vaultKind_, address secondaryManager) = vaultKind(vaultAddr);
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IVaultManager(secondaryManager).addVault(poolId, scId, vaultAddr, asset_, assetId);
        }
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncRequests/asset-mismatch");
        require(vault[poolId][scId][assetId] != address(0), "SyncRequests/vault-does-not-exist");

        delete vault[poolId][scId][assetId];

        IAuth(token).deny(vaultAddr);
        IShareToken(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);

        (VaultKind vaultKind_, address secondaryManager) = vaultKind(vaultAddr);
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IVaultManager(secondaryManager).removeVault(poolId, scId, vaultAddr, asset_, assetId);
        }
    }

    // --- IDepositManager Writes ---
    /// @inheritdoc IDepositManager
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        auth
        returns (uint256 assets)
    {
        assets = previewMint(vaultAddr, owner, shares);

        _issueShares(vaultAddr, shares.toUint128(), receiver, 0);
    }

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        auth
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        _issueShares(vaultAddr, shares.toUint128(), receiver, assets.toUint128());
    }

    /// @inheritdoc ISyncRequests
    function setValuation(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address valuation_)
        external
        auth
    {
        valuation[poolId][scId][asset][tokenId] = IERC7726(valuation_);

        emit SetValuation(poolId, scId, asset, tokenId, address(valuation_));
    }

    // --- ISyncDepositManager Reads ---
    /// @inheritdoc ISyncDepositManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        return convertToAssets(vaultAddr, shares);
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        return convertToShares(vaultAddr, assets);
    }

    // --- IDepositManager Reads ---
    /// @inheritdoc IDepositManager
    function maxMint(address, /* vaultAddr */ address /* owner */ ) public pure returns (uint256) {
        // TODO(follow-up PR): implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(address, /* vaultAddr */ address /* owner */ ) public pure returns (uint256) {
        // TODO(follow-up PR): implement rate limit
        return type(uint256).max;
    }

    // --- IVaultManager Views ---
    /// @inheritdoc IVaultManager
    function vaultByAssetId(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (address) {
        return vault[poolId][scId][assetId];
    }

    /// @inheritdoc IVaultManager
    function vaultKind(address vaultAddr) public view returns (VaultKind, address) {
        if (IERC165(vaultAddr).supportsInterface(type(IERC7540Redeem).interfaceId)) {
            return (VaultKind.SyncDepositAsyncRedeem, address(IAsyncRedeemVault(vaultAddr).asyncRedeemManager()));
        } else {
            return (VaultKind.Sync, address(0));
        }
    }

    // --- IBaseInvestmentManager Overwrites ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(address vaultAddr, uint256 assets)
        public
        view
        override(IBaseInvestmentManager, BaseInvestmentManager)
        returns (uint256 shares)
    {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        D18 priceAssetPerShare_ = _priceAssetPerShare(
            vault_.poolId(), vault_.trancheId(), vaultDetails.assetId, vault_.asset(), vaultDetails.tokenId
        );

        return super._convertToShares(vault_, vaultDetails, priceAssetPerShare_, assets, MathLib.Rounding.Down);
    }

    // --- IBaseInvestmentManager Overwrites ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(address vaultAddr, uint256 shares)
        public
        view
        override(IBaseInvestmentManager, BaseInvestmentManager)
        returns (uint256 assets)
    {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        D18 priceAssetPerShare_ = _priceAssetPerShare(
            vault_.poolId(), vault_.trancheId(), vaultDetails.assetId, vault_.asset(), vaultDetails.tokenId
        );

        return super._convertToAssets(vault_, vaultDetails, priceAssetPerShare_, shares, MathLib.Rounding.Up);
    }

    /// @inheritdoc ISyncRequests
    function priceAssetPerShare(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (D18 price) {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);

        return _priceAssetPerShare(poolId, scId, assetId, asset, tokenId);
    }

    function prices(uint64 poolId, bytes16 scId, uint128 assetId, address asset, uint256 tokenId)
        public
        view
        returns (SyncPriceData memory priceData)
    {
        IERC7726 valuation_ = valuation[poolId][scId][asset][tokenId];

        (priceData.poolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);
        priceData.assetPerShare = _priceAssetPerShare(poolId, scId, assetId, asset, tokenId, valuation_);

        if (address(valuation_) == address(0)) {
            (priceData.poolPerShare,) = poolManager.pricePoolPerShare(poolId, scId, true);
        } else {
            priceData.poolPerShare = priceData.poolPerAsset * priceData.assetPerShare;
        }
    }

    /// --- Internal methods ---
    /// @dev Issues shares to the receiver and instruct the Balance Sheet Manager to react on the issuance and the
    /// updated holding
    function _issueShares(address vaultAddr, uint128 shares, address receiver, uint128 depositAssetAmount) internal {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        uint64 poolId_ = vault_.poolId();
        bytes16 scId_ = vault_.trancheId();
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);

        SyncPriceData memory priceData =
            prices(poolId_, scId_, vaultDetails.assetId, vault_.asset(), vaultDetails.tokenId);

        PoolId poolId = PoolId.wrap(poolId_);
        ShareClassId scId = ShareClassId.wrap(scId_);

        // Mint shares for receiver & notify CP about issued shares
        balanceSheet.issue(poolId, scId, receiver, priceData.poolPerShare, shares, false);

        _updateHoldings(poolId, scId, vaultDetails, depositAssetAmount, priceData.assetPerShare);
    }

    /// @dev Instructs the balance sheet manager to update holdings and the corresponding value.
    ///      NOTE: Only exists as separate function due to stack-too-deep
    function _updateHoldings(
        PoolId poolId,
        ShareClassId scId,
        VaultDetails memory vaultDetails,
        uint128 depositAssetAmount,
        D18 priceAssetPerShare_
    ) internal {
        // NOTE: We want CP to use the default accounting accounts
        JournalEntry[] memory journalEntries = new JournalEntry[](0);
        Meta memory depositMeta = Meta(journalEntries, journalEntries);

        // Notify CP about updated holdings
        balanceSheet.deposit(
            poolId,
            scId,
            vaultDetails.asset,
            vaultDetails.tokenId,
            escrow,
            depositAssetAmount,
            priceAssetPerShare_,
            depositMeta
        );
    }

    function _priceAssetPerShare(uint64 poolId, bytes16 scId, uint128 assetId, address asset, uint256 tokenId)
        internal
        view
        returns (D18 price)
    {
        IERC7726 valuation_ = valuation[poolId][scId][asset][tokenId];

        return _priceAssetPerShare(poolId, scId, assetId, asset, tokenId, valuation_);
    }

    function _priceAssetPerShare(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address asset,
        uint256 tokenId,
        IERC7726 valuation_
    ) internal view returns (D18 price) {
        if (address(valuation_) == address(0)) {
            (price,) = poolManager.priceAssetPerShare(poolId, scId, assetId, true);
        } else {
            address shareToken = poolManager.shareToken(poolId, scId);

            uint128 assetUnitAmount = uint128(10 ** VaultPricingLib.getAssetDecimals(asset, tokenId));
            uint128 shareUnitAmount = uint128(10 ** IERC20Metadata(shareToken).decimals());
            uint128 assetAmountPerShareUnit = valuation_.getQuote(shareUnitAmount, shareToken, asset).toUint128();

            // Retrieve price by normalizing by asset denomination
            price = d18(assetAmountPerShareUnit, assetUnitAmount);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {d18, D18} from "src/misc/types/D18.sol";

import {UpdateContractMessageLib, UpdateContractType} from "src/spoke/libraries/UpdateContractMessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {BaseRequestManager} from "src/vaults/BaseRequestManager.sol";
import {VaultKind} from "src/spoke/interfaces/IVault.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRedeemVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {ISpoke, VaultDetails} from "src/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";
import {IBaseRequestManager} from "src/vaults/interfaces/IBaseRequestManager.sol";
import {ISyncRequestManager, Prices, ISyncDepositValuation} from "src/vaults/interfaces/IVaultManagers.sol";
import {IDepositManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";
import {IEscrow} from "src/misc/interfaces/IEscrow.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {IVault} from "src/spoke/interfaces/IVaultManager.sol";
import {IVaultManager} from "src/spoke/interfaces/IVaultManager.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncRequestManager is BaseRequestManager, ISyncRequestManager {
    using MathLib for *;
    using CastLib for *;
    using UpdateContractMessageLib for *;
    using BytesLib for bytes;

    mapping(PoolId => mapping(ShareClassId scId => ISyncDepositValuation)) public valuation;
    mapping(PoolId => mapping(ShareClassId scId => mapping(address asset => mapping(uint256 tokenId => uint128))))
        public maxReserve;

    constructor(IEscrow globalEscrow_, address root_, address deployer)
        BaseRequestManager(globalEscrow_, root_, deployer)
    {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseRequestManager
    function file(bytes32 what, address data) external override(IBaseRequestManager, BaseRequestManager) auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId scId, bytes memory payload) external auth {
        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.Valuation)) {
            UpdateContractMessageLib.UpdateContractValuation memory m =
                UpdateContractMessageLib.deserializeUpdateContractValuation(payload);

            require(address(spoke.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());

            setValuation(poolId, scId, m.valuation.toAddress());
        } else if (kind == uint8(UpdateContractType.SyncDepositMaxReserve)) {
            UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve memory m =
                UpdateContractMessageLib.deserializeUpdateContractSyncDepositMaxReserve(payload);

            require(address(spoke.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());
            (address asset, uint256 tokenId) = spoke.idToAsset(AssetId.wrap(m.assetId));

            setMaxReserve(poolId, scId, asset, tokenId, m.maxReserve);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    /// @inheritdoc IVaultManager
    function addVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_, address asset_, uint256 tokenId)
        public
        override(BaseRequestManager, IVaultManager)
        auth
    {
        super.addVault(poolId, scId, assetId, vault_, asset_, tokenId);

        (, uint256 tokenId_) = spoke.idToAsset(assetId);
        setMaxReserve(poolId, scId, asset_, tokenId_, type(uint128).max);

        VaultKind vaultKind_ = vault_.vaultKind();
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IAsyncRedeemManager asyncRequestManager = IAsyncRedeemVault(address(vault_)).asyncRedeemManager();
            require(address(asyncRequestManager) != address(0), SecondaryManagerDoesNotExist());
            asyncRequestManager.addVault(poolId, scId, assetId, vault_, asset_, tokenId);
        }
    }

    /// @inheritdoc IVaultManager
    function removeVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IVault vault_,
        address asset_,
        uint256 tokenId
    ) public override(BaseRequestManager, IVaultManager) auth {
        super.removeVault(poolId, scId, assetId, vault_, asset_, tokenId);

        (, uint256 tokenId_) = spoke.idToAsset(assetId);
        delete maxReserve[poolId][scId][asset_][tokenId_];

        VaultKind vaultKind_ = vault_.vaultKind();
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IAsyncRedeemManager asyncRequestManager = IAsyncRedeemVault(address(vault_)).asyncRedeemManager();
            require(address(asyncRequestManager) != address(0), SecondaryManagerDoesNotExist());
            asyncRequestManager.removeVault(poolId, scId, assetId, vault_, asset_, tokenId);
        }
    }

    /// @inheritdoc ISyncRequestManager
    function setValuation(PoolId poolId, ShareClassId scId, address valuation_) public auth {
        valuation[poolId][scId] = ISyncDepositValuation(valuation_);

        emit SetValuation(poolId, scId, address(valuation_));
    }

    /// @inheritdoc ISyncRequestManager
    function setMaxReserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 maxReserve_)
        public
        auth
    {
        maxReserve[poolId][scId][asset][tokenId] = maxReserve_;

        emit SetMaxReserve(poolId, scId, asset, tokenId, maxReserve_);
    }

    //----------------------------------------------------------------------------------------------
    // Deposit handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function mint(IBaseVault vault_, uint256 shares, address receiver, address owner)
        external
        auth
        returns (uint256 assets)
    {
        require(maxMint(vault_, owner) >= shares, ExceedsMaxMint());
        assets = previewMint(vault_, owner, shares);

        _issueShares(vault_, shares.toUint128(), receiver, assets.toUint128());
    }

    /// @inheritdoc IDepositManager
    function deposit(IBaseVault vault_, uint256 assets, address receiver, address owner)
        external
        auth
        returns (uint256 shares)
    {
        require(maxDeposit(vault_, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vault_, owner, assets);

        _issueShares(vault_, shares.toUint128(), receiver, assets.toUint128());
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISyncDepositManager
    function previewMint(IBaseVault vault_, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        return _shareToAssetAmount(vault_, shares, MathLib.Rounding.Up);
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(IBaseVault vault_, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        return convertToShares(vault_, assets);
    }

    /// @inheritdoc IDepositManager
    function maxMint(IBaseVault vault_, address /* owner */ ) public view returns (uint256) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        uint128 maxAssets =
            _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId, vault_);
        return convertToShares(vault_, maxAssets);
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address /* owner */ ) public view returns (uint256) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        return _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId, vault_);
    }

    /// @inheritdoc IBaseRequestManager
    function convertToShares(IBaseVault vault_, uint256 assets)
        public
        view
        override(IBaseRequestManager, BaseRequestManager)
        returns (uint256 shares)
    {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        Prices memory prices_ = prices(vault_.poolId(), vault_.scId(), vaultDetails.assetId);

        return super._assetToShareAmount(
            vault_, vaultDetails, assets, prices_.poolPerAsset, prices_.poolPerShare, MathLib.Rounding.Down
        );
    }

    /// @inheritdoc IBaseRequestManager
    function convertToAssets(IBaseVault vault_, uint256 shares)
        public
        view
        override(IBaseRequestManager, BaseRequestManager)
        returns (uint256 assets)
    {
        return _shareToAssetAmount(vault_, shares, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncDepositValuation
    function pricePoolPerShare(PoolId poolId, ShareClassId scId) public view returns (D18 price) {
        ISyncDepositValuation valuation_ = valuation[poolId][scId];

        if (address(valuation_) == address(0)) {
            price = spoke.pricePoolPerShare(poolId, scId, true);
        } else {
            price = valuation_.pricePoolPerShare(poolId, scId);
        }
    }

    /// @inheritdoc ISyncRequestManager
    function prices(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (Prices memory priceData) {
        priceData.poolPerShare = pricePoolPerShare(poolId, scId);
        priceData.poolPerAsset = spoke.pricePoolPerAsset(poolId, scId, assetId, true);
        priceData.assetPerShare = PricingLib.priceAssetPerShare(priceData.poolPerShare, priceData.poolPerAsset);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev Issues shares to the receiver and instruct the balance sheet
    //       to react on the issuance and the updated holding.
    function _issueShares(IBaseVault vault_, uint128 shares, address receiver, uint128 assets) internal {
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);

        balanceSheet.overridePricePoolPerShare(poolId, scId, pricePoolPerShare(poolId, scId));
        balanceSheet.issue(poolId, scId, receiver, shares);
        balanceSheet.resetPricePoolPerShare(poolId, scId);

        // Note deposit into the pool escrow, to make assets available for managers of the balance sheet.
        // ERC-20 transfer is handled by the vault to the pool escrow afterwards.
        balanceSheet.noteDeposit(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, assets);
    }

    function _maxDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, IBaseVault vault_)
        internal
        view
        returns (uint128 maxDeposit_)
    {
        if (!spoke.isLinked(vault_)) return 0;

        uint128 availableBalance = balanceSheet.availableBalanceOf(poolId, scId, asset, tokenId);
        uint128 maxReserve_ = maxReserve[poolId][scId][asset][tokenId];

        if (maxReserve_ < availableBalance) {
            maxDeposit_ = 0;
        } else {
            maxDeposit_ = maxReserve_ - availableBalance;
        }
    }

    function _shareToAssetAmount(IBaseVault vault_, uint256 assets, MathLib.Rounding rounding)
        internal
        view
        returns (uint256 shares)
    {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        Prices memory prices_ = prices(vault_.poolId(), vault_.scId(), vaultDetails.assetId);
        return super._shareToAssetAmount(
            vault_, vaultDetails, assets, prices_.poolPerAsset, prices_.poolPerShare, rounding
        );
    }
}

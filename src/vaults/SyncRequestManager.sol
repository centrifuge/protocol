// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC7540Redeem} from "src/misc/interfaces/IERC7540.sol";

import {Auth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {d18, D18} from "src/misc/types/D18.sol";

import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncRedeemVault, IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {
    ISyncRequestManager,
    Prices,
    ISyncDepositValuation
} from "src/vaults/interfaces/investments/ISyncRequestManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncRequestManager is BaseInvestmentManager, ISyncRequestManager {
    using BytesLib for bytes;
    using MathLib for *;
    using CastLib for *;
    using MessageLib for *;

    IBalanceSheet public balanceSheet;

    mapping(PoolId => mapping(ShareClassId scId => mapping(AssetId assetId => IBaseVault))) public vault;
    mapping(PoolId => mapping(ShareClassId scId => mapping(address asset => mapping(uint256 tokenId => uint128))))
        public maxReserve;
    mapping(PoolId => mapping(ShareClassId scId => ISyncDepositValuation)) public valuation;

    constructor(IEscrow globalEscrow_, address root_, address deployer)
        BaseInvestmentManager(globalEscrow_, root_, deployer)
    {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId scId, bytes memory payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.Valuation)) {
            MessageLib.UpdateContractValuation memory m = MessageLib.deserializeUpdateContractValuation(payload);

            require(address(poolManager.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());

            setValuation(poolId, scId, m.valuation.toAddress());
        } else if (kind == uint8(UpdateContractType.SyncDepositMaxReserve)) {
            MessageLib.UpdateContractSyncDepositMaxReserve memory m =
                MessageLib.deserializeUpdateContractSyncDepositMaxReserve(payload);

            require(address(poolManager.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());
            (address asset, uint256 tokenId) = poolManager.idToAsset(AssetId.wrap(m.assetId));

            setMaxReserve(poolId, scId, asset, tokenId, m.maxReserve);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    /// @inheritdoc IVaultManager
    function addVault(PoolId poolId, ShareClassId scId, IBaseVault vault_, address asset_, AssetId assetId)
        external
        override
        auth
    {
        require(vault_.asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) == address(0), VaultAlreadyExists());

        address token = vault_.share();
        vault[poolId][scId][assetId] = vault_;

        (, uint256 tokenId) = poolManager.idToAsset(assetId);
        setMaxReserve(poolId, scId, asset_, tokenId, type(uint128).max);

        IAuth(token).rely(address(vault_));
        IShareToken(token).updateVault(vault_.asset(), address(vault_));
        rely(address(vault_));

        (VaultKind vaultKind_, address secondaryManager) = vaultKind(vault_);
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IVaultManager(secondaryManager).addVault(poolId, scId, vault_, asset_, assetId);
        }
    }

    /// @inheritdoc IVaultManager
    function removeVault(PoolId poolId, ShareClassId scId, IBaseVault vault_, address asset_, AssetId assetId)
        external
        override
        auth
    {
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) != address(0), VaultDoesNotExist());

        delete vault[poolId][scId][assetId];

        (, uint256 tokenId) = poolManager.idToAsset(assetId);
        delete maxReserve[poolId][scId][asset_][tokenId];

        IAuth(token).deny(address(vault_));
        IShareToken(token).updateVault(vault_.asset(), address(0));
        deny(address(vault_));

        (VaultKind vaultKind_, address secondaryManager) = vaultKind(vault_);
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IVaultManager(secondaryManager).removeVault(poolId, scId, vault_, asset_, assetId);
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

        _issueShares(vault_, shares.toUint128(), receiver, owner, assets.toUint128());
    }

    /// @inheritdoc IDepositManager
    function deposit(IBaseVault vault_, uint256 assets, address receiver, address owner)
        external
        auth
        returns (uint256 shares)
    {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        require(poolManager.isLinked(vault_.poolId(), vault_.scId(), vaultDetails.asset, vault_), AssetNotAllowed());

        require(maxDeposit(vault_, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vault_, owner, assets);

        _issueShares(vault_, shares.toUint128(), receiver, owner, assets.toUint128());
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
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        uint128 maxAssets = _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId);
        return convertToShares(vault_, maxAssets);
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address /* owner */ ) public view returns (uint256) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        return _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId);
    }

    /// @inheritdoc IVaultManager
    function vaultByAssetId(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (IBaseVault) {
        return vault[poolId][scId][assetId];
    }

    /// @inheritdoc IVaultManager
    function vaultKind(IBaseVault vault_) public view returns (VaultKind, address) {
        if (IERC165(address(vault_)).supportsInterface(type(IERC7540Redeem).interfaceId)) {
            return (VaultKind.SyncDepositAsyncRedeem, address(IAsyncRedeemVault(address(vault_)).asyncRedeemManager()));
        } else {
            return (VaultKind.Sync, address(0));
        }
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(IBaseVault vault_, uint256 assets)
        public
        view
        override(IBaseInvestmentManager, BaseInvestmentManager)
        returns (uint256 shares)
    {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        Prices memory prices_ = prices(vault_.poolId(), vault_.scId(), vaultDetails.assetId);

        return super._assetToShareAmount(
            vault_, vaultDetails, assets, prices_.poolPerAsset, prices_.poolPerShare, MathLib.Rounding.Down
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(IBaseVault vault_, uint256 shares)
        public
        view
        override(IBaseInvestmentManager, BaseInvestmentManager)
        returns (uint256 assets)
    {
        return _shareToAssetAmount(vault_, shares, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncDepositValuation
    function pricePoolPerShare(PoolId poolId, ShareClassId scId) public view returns (D18 price) {
        ISyncDepositValuation valuation_ = valuation[poolId][scId];

        if (address(valuation_) == address(0)) {
            (price,) = poolManager.pricePoolPerShare(poolId, scId, true);
        } else {
            price = valuation_.pricePoolPerShare(poolId, scId);
        }
    }

    /// @inheritdoc ISyncRequestManager
    function prices(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (Prices memory priceData) {
        priceData.poolPerShare = pricePoolPerShare(poolId, scId);
        (priceData.poolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);
        priceData.assetPerShare = PricingLib.priceAssetPerShare(priceData.poolPerShare, priceData.poolPerAsset);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev Issues shares to the receiver and instruct the balance sheet
    //       to react on the issuance and the updated holding.
    function _issueShares(IBaseVault vault_, uint128 shares, address receiver, address, /* owner */ uint128 assets)
        internal
    {
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);

        balanceSheet.overridePricePoolPerShare(poolId, scId, prices(poolId, scId, vaultDetails.assetId).poolPerShare);
        balanceSheet.issue(poolId, scId, receiver, shares);

        // Note deposit into the pool escrow, to make assets available for managers of the balance sheet
        // ERC-20 transfer is handled by the vault to the pool escrow afterwards
        balanceSheet.noteDeposit(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, receiver, assets);
    }

    function _maxDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        internal
        view
        returns (uint128 maxDeposit_)
    {
        uint128 availableBalance = poolEscrowProvider.escrow(poolId).availableBalanceOf(scId, asset, tokenId);
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
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        Prices memory prices_ = prices(vault_.poolId(), vault_.scId(), vaultDetails.assetId);
        return super._shareToAssetAmount(
            vault_, vaultDetails, assets, prices_.poolPerAsset, prices_.poolPerShare, rounding
        );
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18} from "src/misc/types/D18.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseInvestmentManager, VaultKind} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

abstract contract BaseInvestmentManager is Auth, Recoverable, IBaseInvestmentManager {
    using MathLib for uint256;

    address public immutable root;
    IEscrow public immutable globalEscrow;

    IPoolManager public poolManager;
    IPoolEscrowProvider public poolEscrowProvider;

    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => IBaseVault vault))) public vault;

    constructor(IEscrow globalEscrow_, address root_, address deployer) Auth(deployer) {
        globalEscrow = globalEscrow_;
        root = root_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external virtual auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IBaseInvestmentManager
    function addVault(PoolId poolId, ShareClassId scId, IBaseVault vault_, address asset_, AssetId assetId)
        public
        virtual
        auth
    {
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) == address(0), VaultAlreadyExists());

        vault[poolId][scId][assetId] = IBaseVault(address(vault_));
        IAuth(token).rely(address(vault_));
        IShareToken(token).updateVault(vault_.asset(), address(vault_));
        rely(address(vault_));
    }

    /// @inheritdoc IBaseInvestmentManager
    function removeVault(PoolId poolId, ShareClassId scId, IBaseVault vault_, address asset_, AssetId assetId)
        public
        virtual
        auth
    {
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) != address(0), VaultDoesNotExist());

        delete vault[poolId][scId][assetId];

        IAuth(token).deny(address(vault_));
        IShareToken(token).updateVault(vault_.asset(), address(0));
        deny(address(vault_));
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(IBaseVault vault_, uint256 assets) public view virtual returns (uint256 shares) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        (D18 pricePoolPerAsset, D18 pricePoolPerShare) =
            poolManager.pricesPoolPer(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);

        return _assetToShareAmount(
            vault_, vaultDetails, assets, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(IBaseVault vault_, uint256 shares) public view virtual returns (uint256 assets) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        (D18 pricePoolPerAsset, D18 pricePoolPerShare) =
            poolManager.pricesPoolPer(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);

        return _shareToAssetAmount(
            vault_, vaultDetails, shares, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function priceLastUpdated(IBaseVault vault_) public view virtual returns (uint64 lastUpdated) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);

        (uint64 shareLastUpdated,,) = poolManager.markersPricePoolPerShare(vault_.poolId(), vault_.scId());
        (uint64 assetLastUpdated,,) =
            poolManager.markersPricePoolPerAsset(vault_.poolId(), vault_.scId(), vaultDetails.assetId);

        // Choose the latest update to be the marker
        lastUpdated = MathLib.max(shareLastUpdated, assetLastUpdated).toUint64();
    }

    /// @inheritdoc IBaseInvestmentManager
    function poolEscrow(PoolId poolId) public view returns (IPoolEscrow) {
        return poolEscrowProvider.escrow(poolId);
    }

    /// @inheritdoc IBaseInvestmentManager
    function vaultByAssetId(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (IBaseVault) {
        return vault[poolId][scId][assetId];
    }

    /// @inheritdoc IBaseInvestmentManager
    function vaultKind(IBaseVault) public view virtual returns (VaultKind, address) {
        return (VaultKind.Async, address(0));
    }

    function _assetToShareAmount(
        IBaseVault vault_,
        VaultDetails memory vaultDetails,
        uint256 assets,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint256 shares) {
        return PricingLib.assetToShareAmount(
            vault_.share(),
            vaultDetails.asset,
            vaultDetails.tokenId,
            assets.toUint128(),
            pricePoolPerAsset,
            pricePoolPerShare,
            rounding
        );
    }

    function _shareToAssetAmount(
        IBaseVault vault_,
        VaultDetails memory vaultDetails,
        uint256 shares,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint256 assets) {
        return PricingLib.shareToAssetAmount(
            vault_.share(),
            shares.toUint128(),
            vaultDetails.asset,
            vaultDetails.tokenId,
            pricePoolPerAsset,
            pricePoolPerShare,
            rounding
        );
    }
}

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

import {ISpoke, VaultDetails} from "src/spoke/interfaces/ISpoke.sol";
import {IBaseRequestManager} from "src/spoke/interfaces/investments/IBaseRequestManager.sol";
import {IPoolEscrowProvider} from "src/spoke/interfaces/factories/IPoolEscrowFactory.sol";
import {IBaseVault, VaultKind} from "src/spoke/interfaces/vaults/IBaseVaults.sol";
import {IPoolEscrow, IEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

abstract contract BaseRequestManager is Auth, Recoverable, IBaseRequestManager {
    using MathLib for uint256;

    address public immutable root;
    IEscrow public immutable globalEscrow;

    ISpoke public spoke;
    IPoolEscrowProvider public poolEscrowProvider;

    constructor(IEscrow globalEscrow_, address root_, address deployer) Auth(deployer) {
        globalEscrow = globalEscrow_;
        root = root_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseRequestManager
    function file(bytes32 what, address data) external virtual auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseRequestManager
    function convertToShares(IBaseVault vault_, uint256 assets) public view virtual returns (uint256 shares) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        (D18 pricePoolPerAsset, D18 pricePoolPerShare) =
            spoke.pricesPoolPer(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);

        return _assetToShareAmount(
            vault_, vaultDetails, assets, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
    }

    /// @inheritdoc IBaseRequestManager
    function convertToAssets(IBaseVault vault_, uint256 shares) public view virtual returns (uint256 assets) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        (D18 pricePoolPerAsset, D18 pricePoolPerShare) =
            spoke.pricesPoolPer(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);

        return _shareToAssetAmount(
            vault_, vaultDetails, shares, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
        );
    }

    /// @inheritdoc IBaseRequestManager
    function priceLastUpdated(IBaseVault vault_) public view virtual returns (uint64 lastUpdated) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);

        (uint64 shareLastUpdated,,) = spoke.markersPricePoolPerShare(vault_.poolId(), vault_.scId());
        (uint64 assetLastUpdated,,) =
            spoke.markersPricePoolPerAsset(vault_.poolId(), vault_.scId(), vaultDetails.assetId);

        // Choose the latest update to be the marker
        lastUpdated = MathLib.max(shareLastUpdated, assetLastUpdated).toUint64();
    }

    /// @inheritdoc IBaseRequestManager
    function poolEscrow(PoolId poolId) public view returns (IPoolEscrow) {
        return poolEscrowProvider.escrow(poolId);
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

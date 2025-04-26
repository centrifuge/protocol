// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18} from "src/misc/types/D18.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

abstract contract BaseInvestmentManager is Auth, Recoverable, IBaseInvestmentManager {
    using MathLib for uint256;

    address public immutable root;
    IEscrow public immutable globalEscrow;

    IPoolManager public poolManager;
    IPoolEscrowProvider public poolEscrowProvider;

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

        (, lastUpdated) = poolManager.priceAssetPerShare(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);
    }

    /// @inheritdoc IBaseInvestmentManager
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

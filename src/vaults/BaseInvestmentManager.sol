// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {D18} from "src/misc/types/D18.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

abstract contract BaseInvestmentManager is Auth, Recoverable, IBaseInvestmentManager {
    using MathLib for uint256;

    address public immutable root;

    IPoolManager public poolManager;
    IPoolEscrowProvider public poolEscrowProvider;
    /// @inheritdoc IBaseInvestmentManager
    IEscrow public globalEscrow;

    constructor(IEscrow globalEscrow_, address root_, address deployer) Auth(deployer) {
        globalEscrow = globalEscrow_;
        root = root_;
    }

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external virtual auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    // --- View functions ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(IBaseVault vault_, uint256 assets) public view virtual returns (uint256 shares) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        (D18 priceAssetPerShare,) =
            poolManager.priceAssetPerShare(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);

        return _convertToShares(vault_, vaultDetails, priceAssetPerShare, assets, MathLib.Rounding.Down);
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(IBaseVault vault_, uint256 shares) public view virtual returns (uint256 assets) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        (D18 priceAssetPerShare,) =
            poolManager.priceAssetPerShare(vault_.poolId(), vault_.scId(), vaultDetails.assetId, false);

        return _convertToAssets(vault_, vaultDetails, priceAssetPerShare, shares, MathLib.Rounding.Down);
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

    function _convertToShares(
        IBaseVault vault_,
        VaultDetails memory vaultDetails,
        D18 priceAssetPerShare,
        uint256 assets,
        MathLib.Rounding rounding
    ) internal view returns (uint256 shares) {
        return VaultPricingLib.calculateShares(
            vault_.share(),
            vaultDetails.asset,
            vaultDetails.tokenId,
            assets.toUint128(),
            priceAssetPerShare.raw(),
            rounding
        );
    }

    function _convertToAssets(
        IBaseVault vault_,
        VaultDetails memory vaultDetails,
        D18 priceAssetPerShare,
        uint256 shares,
        MathLib.Rounding rounding
    ) internal view returns (uint256 assets) {
        return VaultPricingLib.calculateAssets(
            vault_.share(),
            shares.toUint128(),
            vaultDetails.asset,
            vaultDetails.tokenId,
            priceAssetPerShare.raw(),
            rounding
        );
    }
}

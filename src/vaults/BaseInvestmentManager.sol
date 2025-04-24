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

import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

abstract contract BaseInvestmentManager is Auth, Recoverable, IBaseInvestmentManager {
    using MathLib for uint256;

    address public immutable root;

    IPoolManager public poolManager;
    IPoolEscrowProvider public poolEscrowProvider;
    /// @inheritdoc IBaseInvestmentManager
    IEscrow public globalEscrow;

    constructor(IPoolEscrow globalEscrow_, address root_, address deployer) Auth(deployer) {
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
    function convertToShares(address vaultAddr, uint256 assets) public view virtual returns (uint256 shares) {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (D18 priceAssetPerShare,) = poolManager.priceAssetPerShare(
            PoolId.wrap(vault_.poolId()), ShareClassId.wrap(vault_.scId()), vaultDetails.assetId, false
        );

        return _convertToShares(vault_, vaultDetails, priceAssetPerShare, assets, MathLib.Rounding.Down);
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(address vaultAddr, uint256 shares) public view virtual returns (uint256 assets) {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (D18 priceAssetPerShare,) = poolManager.priceAssetPerShare(
            PoolId.wrap(vault_.poolId()), ShareClassId.wrap(vault_.scId()), vaultDetails.assetId, false
        );

        return _convertToAssets(vault_, vaultDetails, priceAssetPerShare, shares, MathLib.Rounding.Down);
    }

    /// @inheritdoc IBaseInvestmentManager
    function priceLastUpdated(address vaultAddr) public view virtual returns (uint64 lastUpdated) {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        (, lastUpdated) = poolManager.priceAssetPerShare(
            PoolId.wrap(vault_.poolId()), ShareClassId.wrap(vault_.scId()), vaultDetails.assetId, false
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function poolEscrow(PoolId poolId) public view returns (IPoolEscrow) {
        return poolEscrowProvider.escrow(poolId.raw());
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

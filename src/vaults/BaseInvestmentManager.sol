// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";

import {Recoverable} from "src/misc/Recoverable.sol";

import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";

abstract contract BaseInvestmentManager is Auth, Recoverable, IBaseInvestmentManager {
    using MathLib for uint256;

    address public immutable root;
    address public immutable escrow;

    IPoolManager public poolManager;

    constructor(address root_, address escrow_) Auth(msg.sender) {
        root = root_;
        escrow = escrow_;
    }

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external virtual auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("BaseInvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    // --- View functions ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(address vaultAddr, uint256 _assets) public view returns (uint256 shares) {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (uint128 latestPrice,) = poolManager.sharePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        shares =
            uint256(VaultPricingLib.calculateShares(_assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(address vaultAddr, uint256 _shares) public view returns (uint256 assets) {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (uint128 latestPrice,) = poolManager.sharePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        assets =
            uint256(VaultPricingLib.calculateAssets(_shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IBaseInvestmentManager
    function priceLastUpdated(address vaultAddr) public view returns (uint64 lastUpdated) {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (, lastUpdated) = poolManager.sharePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
    }
}

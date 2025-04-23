// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

interface ISyncDepositManager is IDepositManager, IVaultManager {
    function previewDeposit(IBaseVault vault, address sender, uint256 assets) external view returns (uint256);
    function previewMint(IBaseVault vault, address sender, uint256 shares) external view returns (uint256);
}

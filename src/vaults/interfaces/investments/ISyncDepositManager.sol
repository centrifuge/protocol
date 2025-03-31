// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";

interface ISyncDepositManager is IDepositManager, IVaultManager {
    function previewDeposit(address vault, address sender, uint256 assets) external view returns (uint256);
    function previewMint(address vault, address sender, uint256 shares) external view returns (uint256);
}

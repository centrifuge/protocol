// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDepositManager} from "src/spoke/interfaces/investments/IDepositManager.sol";
import {IBaseVault} from "src/spoke/interfaces/vaults/IBaseVaults.sol";

interface ISyncDepositManager is IDepositManager {
    function previewDeposit(IBaseVault vault, address sender, uint256 assets) external view returns (uint256);
    function previewMint(IBaseVault vault, address sender, uint256 shares) external view returns (uint256);
}

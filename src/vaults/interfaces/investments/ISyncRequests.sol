// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";

interface ISyncRequests is ISyncDepositManager {
    error ExceedsMaxDeposit();
    error AssetNotAllowed();
}

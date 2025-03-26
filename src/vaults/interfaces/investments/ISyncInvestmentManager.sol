// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";

interface ISyncInvestmentManager is IVaultManager, ISyncDepositManager, IMessageHandler {
    error PriceTooOld();
    error ExceedsMaxDeposit();
    error AssetNotAllowed();
}

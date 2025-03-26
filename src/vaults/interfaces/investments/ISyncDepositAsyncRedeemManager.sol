// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";

interface ISyncDepositAsyncRedeemManager is IMessageHandler, ISyncDepositManager, IAsyncRedeemManager {
    error PriceTooOld();
    error ExceedsMaxDeposit();
    error AssetNotAllowed();
}

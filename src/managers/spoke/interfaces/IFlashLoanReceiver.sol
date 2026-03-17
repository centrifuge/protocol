// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IExecutor} from "./IExecutor.sol";
import {IAaveV3Pool} from "./IAaveV3Pool.sol";

interface IFlashLoanReceiver {
    event FlashLoan(address indexed pool, address indexed asset, uint256 amount, address indexed executor);

    error NotPool();
    error NotInitiator();
    error NotActive();

    function requestFlashLoan(
        IAaveV3Pool pool,
        address token,
        uint256 amount,
        IExecutor executor,
        bytes calldata callbackData
    ) external;
}

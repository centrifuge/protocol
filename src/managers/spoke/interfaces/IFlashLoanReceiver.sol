// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAaveV3Pool} from "./IAaveV3Pool.sol";
import {IExecutor} from "./IExecutor.sol";

interface IFlashLoanReceiver {
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

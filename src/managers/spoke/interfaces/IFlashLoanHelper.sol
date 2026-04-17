// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IOnchainPM} from "./IOnchainPM.sol";
import {IAaveV3Pool} from "./IAaveV3Pool.sol";
import {IOnchainPMFactory} from "./IOnchainPMFactory.sol";

interface IFlashLoanHelper {
    event FlashLoan(address indexed pool, address indexed asset, uint256 amount, address indexed onchainPM);

    error NotPool();
    error NotInitiator();
    error NotActive();
    error AlreadyActive();
    error NotOnchainPM();
    error InvalidOnchainPM();

    function factory() external view returns (IOnchainPMFactory);

    function requestFlashLoan(
        IAaveV3Pool pool,
        address token,
        uint256 amount,
        IOnchainPM onchainPM,
        bytes calldata callbackData
    ) external;
}

// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";

import {IDepositManager, IWithdrawManager} from "src/managers/interfaces/IBalanceSheetManager.sol";

interface IOnOfframpManager is IDepositManager, IWithdrawManager, IUpdateContract {
    event UpdateOnramp(address indexed asset, bool isEnabled);
    event UpdateRelayer(address indexed relayer, bool isEnabled);
    event UpdateOfframp(address indexed asset, address receiver);

    error NotAllowedOnrampAsset();
    error InvalidAmount();
    error InvalidOfframpDestination();
    error InvalidPoolId();
    error NotAuthorized();
    error ERC6909NotSupported();
}

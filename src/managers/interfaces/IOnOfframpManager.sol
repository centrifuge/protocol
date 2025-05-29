// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";

import {IDepositManager, IWithdrawManager} from "src/managers/interfaces/IBalanceSheetManager.sol";

interface IOnOfframpManager is IDepositManager, IWithdrawManager, IUpdateContract {
    event UpdateRelayer(address who, bool canManage);
    event UpdatePermissionless(bytes32 what, bool isSet);
    event UpdateOnramp(address indexed asset, bool isEnabled);
    event UpdateOfframp(address indexed asset, address receiver, bool isEnabled);

    error NotAllowedOnrampAsset();
    error InvalidAmount();
    error InvalidOfframpDestination();
    error InvalidPoolId();
    error NotAuthorized();
}

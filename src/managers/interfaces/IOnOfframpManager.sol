// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IDepositManager, IWithdrawManager} from "./IBalanceSheetManager.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

import {IUpdateContract} from "../../spoke/interfaces/IUpdateContract.sol";

interface IOnOfframpManager is IDepositManager, IWithdrawManager, IUpdateContract {
    event UpdateOnramp(address indexed asset, bool isEnabled);
    event UpdateRelayer(address indexed relayer, bool isEnabled);
    event UpdateOfframp(address indexed asset, address receiver, bool isEnabled);

    error NotAllowedOnrampAsset();
    error InvalidAmount();
    error InvalidOfframpDestination();
    error InvalidPoolId();
    error InvalidShareClassId();
    error NotSpoke();
    error NotRelayer();
    error ERC6909NotSupported();
    error UnknownUpdateContractKind();

    function poolId() external view returns (PoolId);
    function scId() external view returns (ShareClassId);
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ISimplePriceManager} from "./ISimplePriceManager.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface ISimplePriceManagerFactory {
    event DeploySimplePriceManager(PoolId indexed poolId, ShareClassId indexed scId, address indexed manager);

    error InvalidShareClassCount();

    function newManager(PoolId poolId, ShareClassId scId) external returns (ISimplePriceManager);
}

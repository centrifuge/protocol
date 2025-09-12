// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ISimplePriceManager} from "./ISimplePriceManager.sol";

import {PoolId} from "../../common/types/PoolId.sol";

interface ISimplePriceManagerFactory {
    event DeploySimplePriceManager(PoolId indexed poolId, address indexed manager);

    error InvalidShareClassCount();

    function newManager(PoolId poolId) external returns (ISimplePriceManager);
}

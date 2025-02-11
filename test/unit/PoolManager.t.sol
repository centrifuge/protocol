// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";

import {IERC7726} from "src/interfaces/IERC7726.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {IAccounting} from "src/interfaces/IAccounting.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IGateway} from "src/interfaces/IGateway.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";

import {Multicall} from "src/Multicall.sol";
import {PoolManager} from "src/PoolManager.sol";

contract TestCommon is Test {
    IPoolRegistry immutable poolRegistry = IPoolRegistry(makeAddr("PoolRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IAssetManager immutable assetManager = IAssetManager(makeAddr("AssetManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    Multicall multicall = new Multicall();
    PoolManager poolManager =
        new PoolManager(multicall, poolRegistry, assetManager, accounting, holdings, gateway, address(0));
}

contract TestPoolAdminChecks is TestCommon {
    function testErrPoolLocked() public {
        vm.startPrank(makeAddr("unauthorizedAddress"));

        vm.expectRevert(IPoolLocker.PoolLocked.selector);
        poolManager.notifyPool(0);

        vm.expectRevert(IPoolLocker.PoolLocked.selector);
        poolManager.notifyShareClass(0, ShareClassId.wrap(0));

        vm.expectRevert(IPoolLocker.PoolLocked.selector);
        poolManager.notifyAllowedAsset(ShareClassId.wrap(0), AssetId.wrap(0));

        // TODO: all pool admin methods

        vm.stopPrank();
    }
}

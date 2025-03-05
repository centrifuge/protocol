// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {IPoolManager} from "src/pools/interfaces/IPoolManager.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {PoolRouter, IPoolRouter} from "src/pools/PoolRouter.sol";

contract TestCommon is Test {
    IPoolManager immutable poolManager = IPoolManager(makeAddr("PoolManager"));
    IPoolRegistry immutable poolRegistry = IPoolRegistry(makeAddr("PoolRegistry"));
    PoolRouter immutable poolRouter = new PoolRouter(poolManager, poolRegistry);
}

contract TestMainMethodsChecks is TestCommon {
    function testErrPoolLocked() public {
        vm.startPrank(makeAddr("noPoolAdmin"));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.notifyPool(0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.notifyShareClass(0, ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.setPoolMetadata(bytes(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.allowPoolAdmin(address(0), false);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.allowAsset(ShareClassId.wrap(0), AssetId.wrap(0), false);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.addShareClass("", "", bytes32(0), bytes(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.approveDeposits(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.approveRedeems(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.issueShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.revokeShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.createHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.increaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.decreaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.updateHolding(ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.updateHoldingValuation(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.setHoldingAccountId(ShareClassId.wrap(0), AssetId.wrap(0), AccountId.wrap(0));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.createAccount(AccountId.wrap(0), false);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.setAccountMetadata(AccountId.wrap(0), bytes(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.addDebit(AccountId.wrap(0), 0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.addCredit(AccountId.wrap(0), 0);

        vm.stopPrank();
    }
}

contract TestExecute is TestCommon {
    function testErrNotAuthoredAdmin() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.isAdmin.selector, PoolId.wrap(1), address(this)),
            abi.encode(false)
        );

        vm.expectRevert(IPoolRouter.NotAuthorizedAdmin.selector);
        poolRouter.execute(PoolId.wrap(1), new bytes[](0));
    }
}

contract TestNestedExecute is TestCommon {
    function testErrNotAuthoredAdmin() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(IPoolRegistry.isAdmin.selector, PoolId.wrap(1), address(this)),
            abi.encode(true)
        );

        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.unlockAccounting.selector, PoolId.wrap(1)),
            abi.encode(true)
        );

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(poolRouter.execute.selector, PoolId.wrap(1), new bytes[](0));

        vm.expectRevert(IPoolRouter.PoolAlreadyUnlocked.selector);
        poolRouter.execute(PoolId.wrap(1), calls);
    }
}

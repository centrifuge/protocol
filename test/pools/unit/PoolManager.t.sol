// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IHoldings} from "src/pools/interfaces/IHoldings.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {IGateway} from "src/pools/interfaces/IGateway.sol";
import {IPoolManager} from "src/pools/interfaces/IPoolManager.sol";
import {PoolManager} from "src/pools/PoolManager.sol";

contract TestCommon is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);

    IPoolRegistry immutable poolRegistry = IPoolRegistry(makeAddr("PoolRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IAssetRegistry immutable assetRegistry = IAssetRegistry(makeAddr("AssetRegistry"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    PoolManager poolManager = new PoolManager(poolRegistry, assetRegistry, accounting, holdings, gateway, address(this));

    function setUp() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.isAdmin.selector, POOL_A, ADMIN),
            abi.encode(true)
        );

        vm.mockCall(
            address(accounting), abi.encodeWithSelector(accounting.unlock.selector, POOL_A, "TODO"), abi.encode(true)
        );
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthotized() public {
        vm.startPrank(makeAddr("noPoolAdmin"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.notifyPool(0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.notifyShareClass(0, ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.setPoolMetadata(bytes(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.allowPoolAdmin(address(0), false);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.allowAsset(ShareClassId.wrap(0), AssetId.wrap(0), false);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.addShareClass("", "", bytes32(0), bytes(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.approveDeposits(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.approveRedeems(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.issueShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.revokeShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.createHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.increaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.decreaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.updateHolding(ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.updateHoldingValuation(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.setHoldingAccountId(ShareClassId.wrap(0), AssetId.wrap(0), AccountId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.createAccount(AccountId.wrap(0), false);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.setAccountMetadata(AccountId.wrap(0), bytes(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.addDebit(AccountId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.addCredit(AccountId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.registerAsset(AssetId.wrap(0), "", "", 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.depositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.redeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.cancelDepositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.cancelRedeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.stopPrank();
    }

    function testErrPoolLocked() public {
        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.notifyPool(0);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.notifyShareClass(0, ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.setPoolMetadata(bytes(""));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.allowPoolAdmin(address(0), false);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.allowAsset(ShareClassId.wrap(0), AssetId.wrap(0), false);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.addShareClass("", "", bytes32(0), bytes(""));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.approveDeposits(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.approveRedeems(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.issueShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.revokeShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.createHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.increaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.decreaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.updateHolding(ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.updateHoldingValuation(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.setHoldingAccountId(ShareClassId.wrap(0), AssetId.wrap(0), AccountId.wrap(0));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.createAccount(AccountId.wrap(0), false);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.setAccountMetadata(AccountId.wrap(0), bytes(""));

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.addDebit(AccountId.wrap(0), 0);

        vm.expectRevert(IPoolManager.PoolLocked.selector);
        poolManager.addCredit(AccountId.wrap(0), 0);

        vm.stopPrank();
    }
}

contract TestUnlock is TestCommon {
    function testErrNotAuthoredAdmin() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.isAdmin.selector, PoolId.wrap(1), address(2)),
            abi.encode(false)
        );

        vm.expectRevert(IPoolManager.NotAuthorizedAdmin.selector);
        poolManager.unlock(PoolId.wrap(1), address(2));
    }

    function testErrPoolAlreadyUnlocked() public {
        poolManager.unlock(PoolId.wrap(1), ADMIN);

        vm.expectRevert(IPoolManager.PoolAlreadyUnlocked.selector);
        poolManager.unlock(PoolId.wrap(1), ADMIN);
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        poolManager.unlock(POOL_A, ADMIN);

        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.shareClassManager.selector, POOL_A),
            abi.encode(scm)
        );

        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        poolManager.notifyShareClass(23, SC_A, bytes32(""));
    }
}

contract TestAllowAsset is TestCommon {
    function testErrHoldingNotFound() public {
        poolManager.unlock(POOL_A, ADMIN);

        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(holdings.exists.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        poolManager.allowAsset(SC_A, ASSET_A, false);
    }
}

contract TestCreateHolding is TestCommon {
    function testErrAssetNotFound() public {
        poolManager.unlock(POOL_A, ADMIN);

        vm.mockCall(
            address(assetRegistry),
            abi.encodeWithSelector(assetRegistry.isRegistered.selector, ASSET_A),
            abi.encode(false)
        );

        vm.expectRevert(IAssetRegistry.AssetNotFound.selector);
        poolManager.createHolding(SC_A, ASSET_A, IERC7726(address(1)), 0);
    }
}

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
import {IPoolManager, IPoolManagerHandler, IPoolManagerAdminMethods} from "src/pools/interfaces/IPoolManager.sol";
import {PoolManager} from "src/pools/PoolManager.sol";

contract TestCommon is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);

    IPoolRegistry immutable poolRegistry = IPoolRegistry(makeAddr("PoolRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IAssetRegistry immutable assetRegistry = IAssetRegistry(makeAddr("AssetRegistry"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    PoolManager poolManager = new PoolManager(poolRegistry, assetRegistry, accounting, holdings, gateway, address(this));
}

contract TestMainMethodsChecks is TestCommon {
    function testErrPoolLocked() public {
        vm.startPrank(makeAddr("unauthorizedAddress"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.notifyPool(0, PoolId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.notifyShareClass(0, PoolId.wrap(0), ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.setPoolMetadata(PoolId.wrap(0), bytes(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.allowPoolAdmin(PoolId.wrap(0), address(0), false);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.allowAsset(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), false);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.addShareClass(PoolId.wrap(0), "", "", bytes(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.approveDeposits(
            PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0))
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.approveRedeems(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.issueShares(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.revokeShares(
            PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0))
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.createHolding(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.increaseHolding(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.decreaseHolding(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.updateHolding(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.updateHoldingValuation(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.setHoldingAccountId(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), AccountId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.createAccount(PoolId.wrap(0), AccountId.wrap(0), false);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.setAccountMetadata(PoolId.wrap(0), AccountId.wrap(0), bytes(""));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.addDebit(AccountId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.addCredit(AccountId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.handleRegisterAsset(AssetId.wrap(0), "", "", 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.handleDepositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.handleRedeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.handleCancelDepositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.handleCancelRedeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.stopPrank();
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.shareClassManager.selector, POOL_A),
            abi.encode(scm)
        );

        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        poolManager.notifyShareClass(23, POOL_A, SC_A, bytes32(""));
    }
}

contract TestAllowAsset is TestCommon {
    function testErrHoldingNotFound() public {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(holdings.exists.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        poolManager.allowAsset(POOL_A, SC_A, ASSET_A, false);
    }
}

contract TestCreateHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(assetRegistry),
            abi.encodeWithSelector(assetRegistry.isRegistered.selector, ASSET_A),
            abi.encode(false)
        );

        vm.expectRevert(IAssetRegistry.AssetNotFound.selector);
        poolManager.createHolding(POOL_A, SC_A, ASSET_A, IERC7726(address(1)), 0);
    }
}

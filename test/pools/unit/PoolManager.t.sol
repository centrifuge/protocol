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

    PoolManager poolManager = new PoolManager(poolRegistry, assetRegistry, accounting, holdings, gateway, address(0));

    function _mockSuccessfulMulticall() private {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(IPoolRegistry.isAdmin.selector, PoolId.wrap(1), address(this)),
            abi.encode(true)
        );

        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.unlock.selector, PoolId.wrap(1), bytes32("TODO")),
            abi.encode(true)
        );
    }

    function setUp() public {
        _mockSuccessfulMulticall();
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrPoolLocked() public {
        vm.startPrank(makeAddr("notPoolAdmin"));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.notifyPool(0);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.notifyShareClass(0, ShareClassId.wrap(0));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.setPoolMetadata(bytes(""));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.allowPoolAdmin(address(0), false);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.allowInvestorAsset(ShareClassId.wrap(0), AssetId.wrap(0), false);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.addShareClass(bytes(""));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.approveDeposits(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.approveRedeems(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.issueShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.revokeShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.createHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.increaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.decreaseHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), 0);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.updateHolding(ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.updateHoldingValuation(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.setHoldingAccountId(ShareClassId.wrap(0), AssetId.wrap(0), AccountId.wrap(0));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.createAccount(AccountId.wrap(0), false);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.setAccountMetadata(AccountId.wrap(0), bytes(""));

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.addDebit(AccountId.wrap(0), 0);

        vm.expectRevert(IPoolManagerAdminMethods.PoolLocked.selector);
        poolManager.addCredit(AccountId.wrap(0), 0);

        vm.stopPrank();
    }

    function testErrNotGateway() public {
        vm.startPrank(makeAddr("notGateway"));

        vm.expectRevert(IPoolManagerHandler.NotGateway.selector);
        poolManager.handleRegisterAsset(AssetId.wrap(0), "", "", 0);

        vm.expectRevert(IPoolManagerHandler.NotGateway.selector);
        poolManager.handleRequestDeposit(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IPoolManagerHandler.NotGateway.selector);
        poolManager.handleRequestRedeem(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IPoolManagerHandler.NotGateway.selector);
        poolManager.handleCancelDepositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IPoolManagerHandler.NotGateway.selector);
        poolManager.handleCancelRedeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

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

        vm.expectRevert(IPoolManagerAdminMethods.NotAuthorizedAdmin.selector);
        poolManager.execute(PoolId.wrap(1), new bytes[](0));
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

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(poolManager.notifyShareClass.selector, 23, SC_A);

        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        poolManager.execute(POOL_A, calls);
    }
}

contract TestAllowInvestorAsset is TestCommon {
    function testErrHoldingNotFound() public {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(holdings.exists.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(poolManager.allowInvestorAsset.selector, SC_A, ASSET_A, false);

        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        poolManager.execute(POOL_A, calls);
    }
}

contract TestCreateHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(assetRegistry),
            abi.encodeWithSelector(assetRegistry.isRegistered.selector, ASSET_A),
            abi.encode(false)
        );

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(poolManager.createHolding.selector, SC_A, ASSET_A, address(1), 0);

        vm.expectRevert(IAssetRegistry.AssetNotFound.selector);
        poolManager.execute(POOL_A, calls);
    }
}

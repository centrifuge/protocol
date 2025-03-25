// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IHoldings} from "src/pools/interfaces/IHoldings.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {IPoolRouter} from "src/pools/interfaces/IPoolRouter.sol";
import {PoolRouter} from "src/pools/PoolRouter.sol";

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);

    IPoolRegistry immutable poolRegistry = IPoolRegistry(makeAddr("PoolRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IAssetRegistry immutable assetRegistry = IAssetRegistry(makeAddr("AssetRegistry"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));

    PoolRouter poolRouter = new PoolRouter(poolRegistry, assetRegistry, accounting, holdings, gateway, address(this));

    function setUp() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.isAdmin.selector, POOL_A, ADMIN),
            abi.encode(true)
        );

        vm.mockCall(
            address(accounting), abi.encodeWithSelector(accounting.generateJournalId.selector, POOL_A), abi.encode(1)
        );

        vm.mockCall(
            address(accounting), abi.encodeWithSelector(accounting.unlock.selector, POOL_A, 1), abi.encode(true)
        );

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatch.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatch.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthotized() public {
        vm.startPrank(makeAddr("noPoolAdmin"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolRouter.registerAsset(AssetId.wrap(0), "", "", 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolRouter.depositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolRouter.redeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolRouter.cancelDepositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolRouter.cancelRedeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.stopPrank();
    }

    function testErrPoolLocked() public {
        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.notifyPool(0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.notifyShareClass(0, ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.setPoolMetadata(bytes(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.allowPoolAdmin(address(0), false);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.addShareClass("", "", bytes32(0), bytes(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.approveDeposits(ShareClassId.wrap(0), AssetId.wrap(0), 0, IERC7726(address(0)));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.approveRedeems(ShareClassId.wrap(0), AssetId.wrap(0), 0);

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.issueShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.revokeShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.updateContract(0, ShareClassId.wrap(0), bytes32(0), bytes(""));

        vm.expectRevert(IPoolRouter.PoolLocked.selector);
        poolRouter.updateVault(ShareClassId.wrap(0), AssetId.wrap(0), bytes32(0), bytes32(0), VaultUpdateKind(0));

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

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(poolRegistry.shareClassManager.selector, POOL_A),
            abi.encode(scm)
        );

        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(poolRouter.notifyShareClass.selector, 23, SC_A, bytes32(""));

        vm.prank(ADMIN);
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        poolRouter.execute(POOL_A, cs);
    }
}

contract TestCreateHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(assetRegistry),
            abi.encodeWithSelector(assetRegistry.isRegistered.selector, ASSET_A),
            abi.encode(false)
        );

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(poolRouter.createHolding.selector, SC_A, ASSET_A, IERC7726(address(1)), 0);

        vm.prank(ADMIN);
        vm.expectRevert(IAssetRegistry.AssetNotFound.selector);
        poolRouter.execute(POOL_A, cs);
    }
}

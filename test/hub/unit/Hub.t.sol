// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IHub} from "src/hub/interfaces/IHub.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";
import {Hub} from "src/hub/Hub.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    ITransientValuation immutable transientValuation = ITransientValuation(makeAddr("TransientValuation"));

    Hub hub = new Hub(scm, hubRegistry, accounting, holdings, gateway, transientValuation, address(this));

    function setUp() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isAdmin.selector, POOL_A, ADMIN), abi.encode(true)
        );

        vm.mockCall(address(accounting), abi.encodeWithSelector(accounting.unlock.selector, POOL_A), abi.encode(true));

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthotized() public {
        vm.startPrank(makeAddr("noPoolAdmin"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.registerAsset(AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.depositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.redeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.cancelDepositRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.cancelRedeemRequest(PoolId.wrap(0), ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        JournalEntry[] memory entries = new JournalEntry[](0);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateHoldingAmount(
            PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), 0, D18.wrap(1), false, entries, entries
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateJournal(PoolId.wrap(0), entries, entries);

        vm.stopPrank();
    }

    function testErrPoolLocked() public {
        vm.expectRevert(IHub.PoolLocked.selector);
        hub.notifyPool(0);

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.notifyShareClass(0, ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.notifySharePrice(0, ShareClassId.wrap(0));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.notifyAssetPrice(ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.setPoolMetadata(bytes(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.allowPoolAdmin(address(0), false);

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.addShareClass("", "", bytes32(0), bytes(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.approveDeposits(ShareClassId.wrap(0), AssetId.wrap(0), 0, IERC7726(address(0)));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.approveRedeems(ShareClassId.wrap(0), AssetId.wrap(0), 0);

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.issueShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.revokeShares(ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.updateRestriction(0, ShareClassId.wrap(0), bytes(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.updateContract(0, ShareClassId.wrap(0), bytes32(0), bytes(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.updateVault(ShareClassId.wrap(0), AssetId.wrap(0), bytes32(0), bytes32(0), VaultUpdateKind(0));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.updatePricePoolPerShare(ShareClassId.wrap(0), D18.wrap(0), bytes(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.createHolding(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), false, 0);

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.updateHolding(ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.updateHoldingValuation(ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.setHoldingAccountId(ShareClassId.wrap(0), AssetId.wrap(0), AccountId.wrap(0));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.createAccount(AccountId.wrap(0), false);

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.setAccountMetadata(AccountId.wrap(0), bytes(""));

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.addDebit(AccountId.wrap(0), 0);

        vm.expectRevert(IHub.PoolLocked.selector);
        hub.addCredit(AccountId.wrap(0), 0);

        vm.stopPrank();
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(hub.notifyShareClass.selector, 23, SC_A, bytes32(""));

        vm.prank(ADMIN);
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        hub.execute(POOL_A, cs);
    }
}

contract TestCreateHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isRegistered.selector, ASSET_A), abi.encode(false)
        );

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(hub.createHolding.selector, SC_A, ASSET_A, IERC7726(address(1)), false, 0);

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        hub.execute(POOL_A, cs);
    }
}

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
    JournalEntry[] EMPTY;

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
        vm.startPrank(makeAddr("noGateway"));

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

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateHoldingValue(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateHoldingAmount(
            PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), 0, D18.wrap(1), false, EMPTY, EMPTY
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateJournalEntries(PoolId.wrap(0), EMPTY, EMPTY);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.increaseShareIssuance(PoolId.wrap(0), ShareClassId.wrap(0), D18.wrap(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.decreaseShareIssuance(PoolId.wrap(0), ShareClassId.wrap(0), D18.wrap(0), 0);

        vm.stopPrank();
    }

    function testErrNotAuthorizedAdmin() public {
        vm.startPrank(makeAddr("noPoolAdmin"));
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.isAdmin.selector, POOL_A, makeAddr("noPoolAdmin")),
            abi.encode(false)
        );

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.notifyPool(POOL_A, 0);

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.notifyShareClass(POOL_A, 0, ShareClassId.wrap(0), bytes32(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.notifySharePrice(POOL_A, 0, ShareClassId.wrap(0));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.notifyAssetPrice(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.setPoolMetadata(POOL_A, bytes(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.allowPoolAdmin(POOL_A, address(0), false);

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.addShareClass(POOL_A, "", "", bytes32(0), bytes(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.approveDeposits(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, IERC7726(address(0)));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.approveRedeems(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0);

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.issueShares(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.revokeShares(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), D18.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.updateRestriction(POOL_A, 0, ShareClassId.wrap(0), bytes(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.updateContract(POOL_A, 0, ShareClassId.wrap(0), bytes32(0), bytes(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.updatePricePoolPerShare(POOL_A, ShareClassId.wrap(0), D18.wrap(0), bytes(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.createHolding(
            POOL_A,
            ShareClassId.wrap(0),
            AssetId.wrap(0),
            IERC7726(address(0)),
            AccountId.wrap(0),
            AccountId.wrap(0),
            AccountId.wrap(0),
            AccountId.wrap(0)
        );

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.createLiability(
            POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)), AccountId.wrap(0), AccountId.wrap(0)
        );

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.updateHoldingValuation(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), IERC7726(address(0)));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.setHoldingAccountId(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, AccountId.wrap(0));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.createAccount(POOL_A, AccountId.wrap(0), false);

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.setAccountMetadata(POOL_A, AccountId.wrap(0), bytes(""));

        vm.expectRevert(IHub.NotAuthorizedAdmin.selector);
        hub.updateJournal(POOL_A, EMPTY, EMPTY);

        vm.stopPrank();
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        vm.prank(ADMIN);
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        hub.notifyShareClass(POOL_A, 23, SC_A, bytes32(""));
    }
}

contract TestCreateHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isRegistered.selector, ASSET_A), abi.encode(false)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        hub.createHolding(
            POOL_A,
            SC_A,
            ASSET_A,
            IERC7726(address(1)),
            AccountId.wrap(1),
            AccountId.wrap(1),
            AccountId.wrap(1),
            AccountId.wrap(1)
        );
    }
}

contract TestCreateLiability is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isRegistered.selector, ASSET_A), abi.encode(false)
        );

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(
            hub.createLiability.selector, SC_A, ASSET_A, IERC7726(address(1)), AccountId.wrap(1), AccountId.wrap(1)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        hub.createLiability(POOL_A, SC_A, ASSET_A, IERC7726(address(1)), AccountId.wrap(1), AccountId.wrap(1));
    }
}

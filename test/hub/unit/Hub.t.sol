// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {AccountId} from "../../../src/common/types/AccountId.sol";
import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IValuation} from "../../../src/common/interfaces/IValuation.sol";
import {ISnapshotHook} from "../../../src/common/interfaces/ISnapshotHook.sol";

import {Hub} from "../../../src/hub/Hub.sol";
import {IHoldings} from "../../../src/hub/interfaces/IHoldings.sol";
import {IHubHelpers} from "../../../src/hub/interfaces/IHubHelpers.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {IHub, VaultUpdateKind} from "../../../src/hub/interfaces/IHub.sol";
import {IAccounting, JournalEntry} from "../../../src/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "../../../src/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);
    JournalEntry[] EMPTY;

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHubHelpers immutable hubHelpers = IHubHelpers(makeAddr("HubHelpers"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));

    Hub hub = new Hub(gateway, holdings, hubHelpers, accounting, hubRegistry, scm, address(this));

    function setUp() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, ADMIN), abi.encode(true)
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
        hub.file(bytes32(""), address(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.createPool(PoolId.wrap(0), address(0), AssetId.wrap(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.registerAsset(AssetId.wrap(0), 0);

        bytes memory EMPTY_BYTES;
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.request(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), EMPTY_BYTES);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateHoldingAmount(
            CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), 0, D18.wrap(1), false, true, 0
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.updateShares(CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), 0, true, true, 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.initiateTransferShares(CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), bytes32(""), 0, 0);

        vm.stopPrank();
    }

    function testErrNotManager() public {
        vm.startPrank(makeAddr("noPoolAdmin"));
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, makeAddr("noPoolAdmin")),
            abi.encode(false)
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyPool(POOL_A, 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyShareClass(POOL_A, ShareClassId.wrap(0), 0, bytes32(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyShareMetadata(POOL_A, ShareClassId.wrap(0), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateShareHook(POOL_A, ShareClassId.wrap(0), 0, bytes32(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifySharePrice(POOL_A, ShareClassId.wrap(0), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyAssetPrice(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.setMaxAssetPriceAge(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setMaxSharePriceAge(0, POOL_A, ShareClassId.wrap(0), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setPoolMetadata(POOL_A, bytes(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.setSnapshotHook(POOL_A, ISnapshotHook(address(0)));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHubManager(POOL_A, address(0), false);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateBalanceSheetManager(0, POOL_A, bytes32(0), false);

        vm.expectRevert(IHub.NotManager.selector);
        hub.addShareClass(POOL_A, "", "", bytes32(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.approveDeposits(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.approveRedeems(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.issueShares(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, D18.wrap(0), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.revokeShares(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, D18.wrap(0), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.forceCancelDepositRequest(POOL_A, ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.forceCancelRedeemRequest(POOL_A, ShareClassId.wrap(0), bytes32(0), AssetId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateRestriction(POOL_A, ShareClassId.wrap(0), 0, bytes(""), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateVault(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), bytes32(0), VaultUpdateKind.DeployAndLink, 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateContract(POOL_A, ShareClassId.wrap(0), 0, bytes32(0), bytes(""), 0);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateSharePrice(POOL_A, ShareClassId.wrap(0), D18.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.initializeHolding(
            POOL_A,
            ShareClassId.wrap(0),
            AssetId.wrap(0),
            IValuation(address(0)),
            AccountId.wrap(0),
            AccountId.wrap(0),
            AccountId.wrap(0),
            AccountId.wrap(0)
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.initializeLiability(
            POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), IValuation(address(0)), AccountId.wrap(0), AccountId.wrap(0)
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHoldingValue(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHoldingValuation(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), IValuation(address(0)));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHoldingIsLiability(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), true);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setHoldingAccountId(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, AccountId.wrap(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.createAccount(POOL_A, AccountId.wrap(0), false);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setAccountMetadata(POOL_A, AccountId.wrap(0), bytes(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateJournal(POOL_A, EMPTY, EMPTY);

        vm.stopPrank();
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        vm.prank(ADMIN);
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        hub.notifyShareClass(POOL_A, SC_A, 23, bytes32(""));
    }
}

contract TestInitializeHolding is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isRegistered.selector, ASSET_A), abi.encode(false)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        hub.initializeHolding(
            POOL_A,
            SC_A,
            ASSET_A,
            IValuation(address(1)),
            AccountId.wrap(1),
            AccountId.wrap(1),
            AccountId.wrap(1),
            AccountId.wrap(1)
        );
    }
}

contract TestInitializeLiability is TestCommon {
    function testErrAssetNotFound() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.isRegistered.selector, ASSET_A), abi.encode(false)
        );

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(
            hub.initializeLiability.selector,
            SC_A,
            ASSET_A,
            IValuation(address(1)),
            AccountId.wrap(1),
            AccountId.wrap(1)
        );

        vm.prank(ADMIN);
        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        hub.initializeLiability(POOL_A, SC_A, ASSET_A, IValuation(address(1)), AccountId.wrap(1), AccountId.wrap(1));
    }
}

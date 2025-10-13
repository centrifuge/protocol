// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {d18, D18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {Hub} from "../../../../src/core/hub/Hub.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {IAdapter} from "../../../../src/core/interfaces/IAdapter.sol";
import {IGateway} from "../../../../src/core/interfaces/IGateway.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IFeeHook} from "../../../../src/core/hub/interfaces/IFeeHook.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IValuation} from "../../../../src/core/hub/interfaces/IValuation.sol";
import {IMultiAdapter} from "../../../../src/core/interfaces/IMultiAdapter.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IHub, VaultUpdateKind} from "../../../../src/core/hub/interfaces/IHub.sol";
import {ISnapshotHook} from "../../../../src/core/hub/interfaces/ISnapshotHook.sol";
import {IHubMessageSender} from "../../../../src/core/interfaces/IGatewaySenders.sol";
import {IAccounting, JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

contract MockFeeHook is IFeeHook {
    mapping(PoolId => mapping(ShareClassId => uint32)) public calls;

    function accrue(PoolId poolId, ShareClassId scId) external {
        calls[poolId][scId]++;
    }

    function accrued(PoolId, ShareClassId) external pure returns (uint128 poolAmount) {
        return 0;
    }
}

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    uint16 constant CHAIN_B = 24;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);
    address immutable REFUND = makeAddr("REFUND");
    JournalEntry[] EMPTY;

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));
    IHubMessageSender immutable sender = IHubMessageSender(makeAddr("Sender"));
    MockFeeHook immutable feeHook = new MockFeeHook();

    Hub hub = new Hub(gateway, holdings, accounting, hubRegistry, multiAdapter, scm, address(this));

    function setUp() public {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, ADMIN), abi.encode(true)
        );

        vm.mockCall(address(accounting), abi.encodeWithSelector(accounting.unlock.selector, POOL_A), abi.encode(true));

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endBatching.selector), abi.encode());

        hub.file("feeHook", address(feeHook));
        hub.file("sender", address(sender));
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthorized() public {
        vm.startPrank(makeAddr("noGateway"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.file(bytes32(""), address(0));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hub.createPool(PoolId.wrap(0), address(0), AssetId.wrap(0));

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
        hub.notifyPool(POOL_A, 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyShareClass(POOL_A, ShareClassId.wrap(0), 0, bytes32(""), REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyShareMetadata(POOL_A, ShareClassId.wrap(0), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateShareHook(POOL_A, ShareClassId.wrap(0), 0, bytes32(""), REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifySharePrice(POOL_A, ShareClassId.wrap(0), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.notifyAssetPrice(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setMaxAssetPriceAge(POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setMaxSharePriceAge(POOL_A, ShareClassId.wrap(0), 0, 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.setPoolMetadata(POOL_A, bytes(""));

        vm.expectRevert(IHub.NotManager.selector);
        hub.setSnapshotHook(POOL_A, ISnapshotHook(address(0)));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateHubManager(POOL_A, address(0), false);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateBalanceSheetManager(POOL_A, 0, bytes32(0), false, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.addShareClass(POOL_A, "", "", bytes32(0));

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateRestriction(POOL_A, ShareClassId.wrap(0), 0, bytes(""), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateVault(
            POOL_A, ShareClassId.wrap(0), AssetId.wrap(0), bytes32(0), VaultUpdateKind.DeployAndLink, 0, REFUND
        );

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateContract(POOL_A, ShareClassId.wrap(0), 0, bytes32(0), bytes(""), 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateSharePrice(POOL_A, ShareClassId.wrap(0), D18.wrap(0), uint64(block.timestamp));

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

        vm.expectRevert(IHub.NotManager.selector);
        hub.setAdapters(POOL_A, 0, new IAdapter[](0), new bytes32[](0), 0, 0, REFUND);

        vm.expectRevert(IHub.NotManager.selector);
        hub.updateGatewayManager(POOL_A, 0, bytes32(0), false, REFUND);

        vm.stopPrank();
    }
}

contract TestNotifyShareClass is TestCommon {
    function testErrShareClassNotFound() public {
        vm.mockCall(address(scm), abi.encodeWithSelector(scm.exists.selector, POOL_A, SC_A), abi.encode(false));

        vm.prank(ADMIN);
        vm.expectRevert(IShareClassManager.ShareClassNotFound.selector);
        hub.notifyShareClass(POOL_A, SC_A, 23, bytes32(""), REFUND);
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

contract TestUpdateSharePrice is TestCommon {
    function testUpdateSharePriceAccruesFees() public {
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.updateSharePrice.selector, POOL_A, SC_A, d18(1, 1)),
            abi.encode(false)
        );

        assertEq(feeHook.calls(POOL_A, SC_A), 0);

        vm.prank(ADMIN);
        hub.updateSharePrice(POOL_A, SC_A, d18(1, 1), uint64(block.timestamp));

        assertEq(feeHook.calls(POOL_A, SC_A), 1);
    }
}

contract TestNotifyAssetPrice is TestCommon {
    function testNotifyAssetPriceAccruesFees() public {
        address REFUND = makeAddr("Refund");

        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendNotifyPricePoolPerAsset.selector, POOL_A, SC_A, ASSET_A, d18(1, 1), REFUND
            ),
            abi.encode()
        );

        assertEq(feeHook.calls(POOL_A, SC_A), 0);

        vm.prank(ADMIN);
        hub.notifyAssetPrice(POOL_A, SC_A, ASSET_A, REFUND);

        assertEq(feeHook.calls(POOL_A, SC_A), 1);
    }
}

contract TestPricePoolPerAsset is TestCommon {
    function testPriceWithoutHoldins() public {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        assertEq(hub.pricePoolPerAsset(POOL_A, SC_A, ASSET_A).raw(), d18(1, 1).raw());
    }
}

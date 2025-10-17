// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";
import {Multicall} from "../../../../src/misc/Multicall.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {ShareClassId, newShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBatchedMulticall} from "../../../../src/core/utils/interfaces/IBatchedMulticall.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import {SimplePriceManager} from "../../../../src/managers/hub/SimplePriceManager.sol";
import {ISimplePriceManager} from "../../../../src/managers/hub/interfaces/ISimplePriceManager.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract MockGateway {
    function withBatch(bytes memory data, address) external payable returns (uint256 cost) {
        (bool success, bytes memory returnData) = msg.sender.call{value: msg.value}(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, "Empty revert");

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }
        return 0;
    }
}

contract MockHub is Multicall {
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external payable {}
}

contract SimplePriceManagerTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId immutable SC_1 = newShareClassId(POOL_A, 1);
    ShareClassId immutable SC_2 = newShareClassId(POOL_A, 2);
    uint16 constant CENTRIFUGE_ID_1 = 1;
    uint16 constant CENTRIFUGE_ID_2 = 2;
    uint16 constant CENTRIFUGE_ID_3 = 3;

    AssetId asset1 = newAssetId(1, 1);
    AssetId asset2 = newAssetId(2, 1);

    address hub = address(new MockHub());
    address gateway = address(new MockGateway());
    address hubRegistry = address(new IsContract());
    address shareClassManager = address(new IsContract());
    address hubHelpers = address(new IsContract());

    address unauthorized = makeAddr("unauthorized");
    address hubManager = makeAddr("hubManager");
    address manager = makeAddr("manager");
    address caller = makeAddr("caller");
    address auth = makeAddr("auth");

    SimplePriceManager priceManager;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();
    }

    function _setupMocks() internal {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.shareClassManager.selector), abi.encode(shareClassManager));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IBatchedMulticall.gateway.selector), abi.encode(gateway));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateSharePrice.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.notifySharePrice.selector), abi.encode(uint256(0)));

        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_A, hubManager), abi.encode(true)
        );

        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.shareClassCount.selector, POOL_A),
            abi.encode(1)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.previewShareClassId.selector, POOL_A, 1),
            abi.encode(SC_1)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(100)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(200)
        );
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.lockCallback.selector), abi.encode(address(this)));
    }

    function _deployManager() internal {
        priceManager = new SimplePriceManager(IHub(hub), caller);

        vm.deal(address(priceManager), 1 ether);
    }
}

contract SimplePriceManagerConstructorTest is SimplePriceManagerTest {
    function testConstructorSuccess() public view {
        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);

        assertEq(address(priceManager.hub()), hub);
        assertEq(address(priceManager.shareClassManager()), shareClassManager);
        assertEq(globalNAV, 0);
        assertEq(globalIssuance, 0);
    }
}

contract SimplePriceManagerConfigureTest is SimplePriceManagerTest {
    function testAddNetworkSuccess() public {
        uint16[] memory networks = new uint16[](1);
        networks[0] = CENTRIFUGE_ID_1;

        vm.expectEmit(true, true, true, true);
        emit ISimplePriceManager.UpdateNetworks(POOL_A, networks);

        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);

        uint16[] memory storedNetworks = priceManager.notifiedNetworks(POOL_A);
        assertEq(storedNetworks.length, 1);
        assertEq(storedNetworks[0], CENTRIFUGE_ID_1);

        uint16[] memory networks2 = new uint16[](2);
        networks2[0] = CENTRIFUGE_ID_1;
        networks2[1] = CENTRIFUGE_ID_2;

        vm.expectEmit(true, true, true, true);
        emit ISimplePriceManager.UpdateNetworks(POOL_A, networks2);

        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_2);

        storedNetworks = priceManager.notifiedNetworks(POOL_A);
        assertEq(storedNetworks.length, 2);
        assertEq(storedNetworks[0], CENTRIFUGE_ID_1);
        assertEq(storedNetworks[1], CENTRIFUGE_ID_2);
    }

    function testAddNetworkUnauthorized() public {
        vm.expectRevert(ISimplePriceManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testAddNetworkInvalidShareClassCount() public {
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.shareClassCount.selector, POOL_B),
            abi.encode(2)
        );
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_B, hubManager), abi.encode(true)
        );

        vm.expectRevert(ISimplePriceManager.InvalidShareClassCount.selector);
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_B, CENTRIFUGE_ID_1);
    }

    function testRemoveNetworkSuccess() public {
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_2);
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_3);

        uint16[] memory storedNetworks = priceManager.notifiedNetworks(POOL_A);
        assertEq(storedNetworks.length, 3);

        vm.prank(hubManager);
        priceManager.removeNotifiedNetwork(POOL_A, CENTRIFUGE_ID_2);

        storedNetworks = priceManager.notifiedNetworks(POOL_A);
        assertEq(storedNetworks.length, 2);
        assertEq(storedNetworks[0], CENTRIFUGE_ID_1);
        assertEq(storedNetworks[1], CENTRIFUGE_ID_3);
    }

    function testRemoveNetworkUnauthorized() public {
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);

        vm.expectRevert(ISimplePriceManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.removeNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testRemoveNetworkNotFound() public {
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);

        vm.expectRevert(ISimplePriceManager.NetworkNotFound.selector);
        vm.prank(hubManager);
        priceManager.removeNotifiedNetwork(POOL_A, CENTRIFUGE_ID_2);
    }
}

contract SimplePriceManagerOnUpdateTest is SimplePriceManagerTest {
    function setUp() public override {
        super.setUp();

        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_1);
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_2);
    }

    function testOnUpdateFirstUpdate() public {
        uint128 netAssetValue = 1000;

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateSharePrice.selector, POOL_A, SC_1, d18(10, 1)) // 1000/100 = 10
        );
        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.notifySharePrice.selector, POOL_A, SC_1, CENTRIFUGE_ID_1)
        );
        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.notifySharePrice.selector, POOL_A, SC_1, CENTRIFUGE_ID_2)
        );

        vm.expectEmit(true, true, true, true);
        emit ISimplePriceManager.Update(POOL_A, SC_1, netAssetValue, 100, d18(10, 1));

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, netAssetValue);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 100);
        assertEq(globalNAV, netAssetValue);

        (uint128 networkNAV, uint128 networkIssuance,,,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        assertEq(networkNAV, netAssetValue);
        assertEq(networkIssuance, 100);
    }

    function testOnUpdateSecondNetwork() public {
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        uint128 netAssetValue2 = 1700;

        // (1000+1700)/(100+200) = 9
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateSharePrice.selector, POOL_A, SC_1, d18(9, 1)));

        vm.expectEmit(true, true, true, true);
        emit ISimplePriceManager.Update(POOL_A, SC_1, 2700, 300, d18(9, 1)); // total NAV=2700, total issuance=300

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_2, netAssetValue2);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 300); // 100 + 200
        assertEq(globalNAV, 2700); // 1000 + 1700
    }

    function testOnUpdateExistingNetwork() public {
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(150)
        );

        uint128 newNetAssetValue = 1200;

        vm.expectEmit(true, true, true, true);
        emit ISimplePriceManager.Update(POOL_A, SC_1, 1200, 150, d18(8, 1)); // 1200/150 = 8

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, newNetAssetValue);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 150);
        assertEq(globalNAV, 1200);
    }

    function testOnUpdateUnauthorized() public {
        vm.expectRevert(ISimplePriceManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);
    }

    function testOnUpdateZeroIssuance() public {
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(0)
        );

        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateSharePrice.selector, POOL_A, SC_1, d18(1, 1)));

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 0);
        assertEq(globalNAV, 1000);
    }

    function testInvalidShareClass() public {
        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_2, CENTRIFUGE_ID_1, 1000);
    }
}

contract SimplePriceManagerPricePoolPerShareTest is SimplePriceManagerTest {
    function testPricePoolPerShareWithZeroIssuance() public view {
        // When issuance is 0, should return 1.0
        assertEq(priceManager.pricePoolPerShare(POOL_A).raw(), d18(1, 1).raw());
    }

    function testPricePoolPerShareWithNonZeroIssuance() public {
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        // NAV = 1000, issuance = 100, price = 1000/100 = 10
        assertEq(priceManager.pricePoolPerShare(POOL_A).raw(), d18(10, 1).raw());
    }

    function testPricePoolPerShareMultipleNetworks() public {
        vm.prank(hubManager);
        priceManager.addNotifiedNetwork(POOL_A, CENTRIFUGE_ID_2);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000); // NAV=1000, issuance=100

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_2, 1700); // NAV=1700, issuance=200

        // Total NAV = 2700, total issuance = 300, price = 2700/300 = 9
        assertEq(priceManager.pricePoolPerShare(POOL_A).raw(), d18(9, 1).raw());
    }

    function testPricePoolPerShareAfterUpdate() public {
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        assertEq(priceManager.pricePoolPerShare(POOL_A).raw(), d18(10, 1).raw());

        // Update with new values
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(150)
        );

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1200);

        // NAV = 1200, issuance = 150, price = 1200/150 = 8
        assertEq(priceManager.pricePoolPerShare(POOL_A).raw(), d18(8, 1).raw());
    }

    function testPricePoolPerShareFuzz(uint128 nav, uint128 issuance) public {
        vm.assume(issuance > 0);
        vm.assume(nav > 0);
        vm.assume(uint256(nav) * 1e18 / issuance < type(uint128).max);

        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(issuance)
        );

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, nav);

        uint256 expectedPrice = (uint256(nav) * 1e18) / issuance;
        assertEq(priceManager.pricePoolPerShare(POOL_A).raw(), expectedPrice);
    }
}

contract SimplePriceManagerOnTransferTest is SimplePriceManagerTest {
    function setUp() public override {
        super.setUp();

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_2, 2000);
    }

    function testOnTransferSuccess() public {
        uint128 sharesTransferred = 50;

        vm.expectEmit(true, true, false, true);
        emit ISimplePriceManager.Transfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, sharesTransferred);

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, sharesTransferred);

        (uint128 fromNAV, uint128 fromIssuance, uint128 fromTransferredIn, uint128 fromTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (uint128 toNAV, uint128 toIssuance, uint128 toTransferredIn, uint128 toTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        // Issuance should remain unchanged until next onUpdate
        assertEq(fromIssuance, 100);
        assertEq(toIssuance, 200);

        // Transferred amounts should be updated
        assertEq(fromTransferredOut, 50);
        assertEq(fromTransferredIn, 0);
        assertEq(toTransferredIn, 50);
        assertEq(toTransferredOut, 0);

        // NAV should remain unchanged
        assertEq(fromNAV, 1000);
        assertEq(toNAV, 2000);
    }

    function testOnTransferUnauthorized() public {
        vm.expectRevert(ISimplePriceManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 50);
    }

    function testOnTransferZeroShares() public {
        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 0);

        (, uint128 fromIssuance,,,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, uint128 toIssuance,,,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(fromIssuance, 100);
        assertEq(toIssuance, 200);
    }

    function testInvalidShareClass() public {
        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_2, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 50);
    }

    function testOnTransferWithUpdate() public {
        uint128 sharesTransferred = 50;

        (, uint128 initialGlobalIssuance) = priceManager.metrics(POOL_A);
        assertEq(initialGlobalIssuance, 300); // 100 + 200

        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(50) // 100 - 50
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(250) // 200 + 50
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, sharesTransferred);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        (, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        (, uint128 fromIssuance, uint128 fromTransferredIn, uint128 fromTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, uint128 toIssuance, uint128 toTransferredIn, uint128 toTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        // fromIssuance is now the same as in ShareClassManager
        // global issuance remains unchanged
        assertEq(globalIssuance, 300);

        // toIssuance is still stale until we call onUpdate for that network
        assertEq(fromIssuance, 50);
        assertEq(toIssuance, 200);

        assertEq(fromTransferredOut, 0);
        assertEq(fromTransferredIn, 0);
        assertEq(toTransferredIn, 50);
        assertEq(toTransferredOut, 0);

        // Update the first network again, just to make sure it doesn't break anything
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        (, globalIssuance) = priceManager.metrics(POOL_A);
        (, fromIssuance, fromTransferredIn, fromTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, toIssuance, toTransferredIn, toTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(globalIssuance, 300);
        assertEq(fromIssuance, 50);
        assertEq(toIssuance, 200);
        assertEq(fromTransferredOut, 0);
        assertEq(fromTransferredIn, 0);
        assertEq(toTransferredIn, 50);
        assertEq(toTransferredOut, 0);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_2, 2000);

        (, globalIssuance) = priceManager.metrics(POOL_A);
        (, fromIssuance, fromTransferredIn, fromTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, toIssuance, toTransferredIn, toTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(globalIssuance, 300);
        assertEq(fromIssuance, 50);
        assertEq(toIssuance, 250);
        assertEq(fromTransferredOut, 0);
        assertEq(fromTransferredIn, 0);
        assertEq(toTransferredIn, 0);
        assertEq(toTransferredOut, 0);

        // Change in shares in ShareClassManager from remote issuance
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(80)
        );

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1200);

        (, globalIssuance) = priceManager.metrics(POOL_A);
        (, fromIssuance, fromTransferredIn, fromTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, toIssuance, toTransferredIn, toTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(globalIssuance, 330);
        assertEq(fromIssuance, 80);
        assertEq(toIssuance, 250);
    }

    function testOnTransferMultipleTransfersBeforeUpdate() public {
        // Transfer 30 shares from network 1 to 2
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(70)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(230)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 30);

        // Transfer another 20 shares from network 1 to 2
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(50)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(250)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 20);

        (, uint128 fromIssuance, uint128 fromTransferredIn, uint128 fromTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, uint128 toIssuance, uint128 toTransferredIn,,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        // Transferred amounts should accumulate
        assertEq(fromTransferredOut, 50); // 30 + 20
        assertEq(toTransferredIn, 50); // 30 + 20
        assertEq(fromIssuance, 100); // Not updated yet
        assertEq(toIssuance, 200); // Not updated yet

        // Update network 1
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        (, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        (, fromIssuance, fromTransferredIn, fromTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);

        // Global issuance should remain 300 (100 + 200)
        // because transferred amounts net to zero globally
        assertEq(globalIssuance, 300);
        assertEq(fromIssuance, 50);
        assertEq(fromTransferredOut, 0); // Reset after update
        assertEq(fromTransferredIn, 0);
    }

    function testOnTransferBidirectional() public {
        // Transfer 30 shares from network 1 to 2
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(70)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(230)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 30);

        // Transfer 10 shares back from network 2 to 1
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(80)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(220)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_2, CENTRIFUGE_ID_1, 10);

        (, uint128 fromIssuance, uint128 fromTransferredIn, uint128 fromTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, uint128 toIssuance, uint128 toTransferredIn, uint128 toTransferredOut,,) =
            priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        // Network 1: out 30, in 10 = net out 20
        assertEq(fromTransferredOut, 30);
        assertEq(fromTransferredIn, 10);
        assertEq(fromIssuance, 100); // Not updated yet

        // Network 2: in 30, out 10 = net in 20
        assertEq(toTransferredIn, 30);
        assertEq(toTransferredOut, 10);
        assertEq(toIssuance, 200); // Not updated yet

        // Update network 1
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        (, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        (, fromIssuance, fromTransferredIn, fromTransferredOut,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);

        // Global should remain 300
        assertEq(globalIssuance, 300);
        // Network 1 issuance should be 80 (as in SCM)
        assertEq(fromIssuance, 80);
        // Transferred amounts should be reset
        assertEq(fromTransferredOut, 0);
        assertEq(fromTransferredIn, 0);
    }
}

contract SimplePriceManagerIssuanceDeltaEdgeCasesTest is SimplePriceManagerTest {
    function setUp() public override {
        super.setUp();

        // Initial update for both networks to set them up
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);
        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_2, 2000);
    }

    function testDeltaCalculationNoTransfers() public {
        // Simple case: issuance increases with no transfers
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(150) // Increased from 100 to 150
        );

        (, uint128 initialGlobal) = priceManager.metrics(POOL_A);
        assertEq(initialGlobal, 300);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1500);

        (, uint128 finalGlobal) = priceManager.metrics(POOL_A);
        assertEq(finalGlobal, 350); // 300 + 50
    }

    function testDeltaCalculationWithTransferIn() public {
        // Issuance increases but part of it is from transfers
        // Transfer 30 in
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(130)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(170)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_2, CENTRIFUGE_ID_1, 30);

        // Now update with SCM showing issuance of 150 (100 + 30 transferred + 20 new issuance)
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(150)
        );

        (, uint128 initialGlobal) = priceManager.metrics(POOL_A);
        assertEq(initialGlobal, 300);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1500);

        (, uint128 finalGlobal) = priceManager.metrics(POOL_A);
        // Delta = (150 + 0) - (100 + 30) = 150 - 130 = 20
        // Global = 300 + 20 = 320
        assertEq(finalGlobal, 320);
    }

    function testDeltaCalculationWithTransferOut() public {
        // Issuance decreases from transfers
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(70)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(230)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 30);

        // Update with new issuance showing 90 (70 from SCM after transfer + 20 new issuance)
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(90)
        );

        (, uint128 initialGlobal) = priceManager.metrics(POOL_A);
        assertEq(initialGlobal, 300);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1500);

        (, uint128 finalGlobal) = priceManager.metrics(POOL_A);
        // Delta = (90 + 30) - (100 + 0) = 120 - 100 = 20
        // Global = 300 + 20 = 320
        assertEq(finalGlobal, 320);
    }

    function testDeltaCalculationDecrease() public {
        // Issuance decreases (revocation)
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(80) // Decreased from 100 to 80
        );

        (, uint128 initialGlobal) = priceManager.metrics(POOL_A);
        assertEq(initialGlobal, 300);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1200);

        (, uint128 finalGlobal) = priceManager.metrics(POOL_A);
        assertEq(finalGlobal, 280); // 300 - 20
    }

    function testDeltaCalculationDecreaseWithTransferIn() public {
        // Net decrease despite transfer in
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(130)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_2),
            abi.encode(170)
        );

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_2, CENTRIFUGE_ID_1, 30);

        // Now update showing net revocation: 110 (100 + 30 transferred - 20 revoked)
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, POOL_A, SC_1, CENTRIFUGE_ID_1),
            abi.encode(110)
        );

        (, uint128 initialGlobal) = priceManager.metrics(POOL_A);
        assertEq(initialGlobal, 300);

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1500);

        (, uint128 finalGlobal) = priceManager.metrics(POOL_A);
        // Delta = (110 + 0) - (100 + 30) = 110 - 130 = -20 (decrease)
        // Global = 300 - 20 = 280
        assertEq(finalGlobal, 280);
    }
}

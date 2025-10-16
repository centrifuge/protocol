// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";
import {Multicall} from "../../../../src/misc/Multicall.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {CrosschainBatcher} from "../../../../src/core/messaging/CrosschainBatcher.sol";
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
        vm.mockCall(hub, abi.encodeWithSelector(IHub.gateway.selector), abi.encode(gateway));
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
        CrosschainBatcher batcher = new CrosschainBatcher(IGateway(gateway), address(this));
        priceManager = new SimplePriceManager(IHub(hub), batcher, caller);

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

        (uint128 networkNAV, uint128 networkIssuance,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
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

        (uint128 fromNAV, uint128 fromIssuance,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (uint128 toNAV, uint128 toIssuance,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(fromIssuance, 50); // 100 - 50
        assertEq(toIssuance, 250); // 200 + 50

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

        (, uint128 fromIssuance,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, uint128 toIssuance,,) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(fromIssuance, 100);
        assertEq(toIssuance, 200);
    }

    function testInvalidShareClass() public {
        vm.expectRevert(ISimplePriceManager.InvalidShareClass.selector);
        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_2, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 50);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {Multicall} from "../../../../src/misc/Multicall.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../../../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/common/types/AssetId.sol";

import {IGateway} from "../../../../src/common/interfaces/IGateway.sol";
import {IHub} from "../../../../src/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../../src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../../../src/hub/interfaces/IShareClassManager.sol";

import {ISimplePriceManager} from "../../../../src/managers/hub/interfaces/ISimplePriceManager.sol";
import {SimplePriceManager} from "../../../../src/managers/hub/SimplePriceManager.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract MockHub is Multicall {
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external payable {}
}

contract SimplePriceManagerTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));
    uint16 constant CENTRIFUGE_ID_1 = 1;
    uint16 constant CENTRIFUGE_ID_2 = 2;
    uint16 constant CENTRIFUGE_ID_3 = 3;

    AssetId asset1 = newAssetId(1, 1);
    AssetId asset2 = newAssetId(2, 1);

    address hub = address(new MockHub());
    address gateway = address(new IsContract());
    address hubRegistry = address(new IsContract());
    address shareClassManager = address(new IsContract());

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

        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.startBatching.selector), abi.encode());
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.endBatching.selector), abi.encode());

        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateSharePrice.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.notifySharePrice.selector), abi.encode(uint256(0)));
        vm.mockCall(
            hub, abi.encodeWithSelector(IHub.approveDeposits.selector), abi.encode(uint256(0), uint128(0), uint128(0))
        );
        vm.mockCall(
            hub,
            abi.encodeWithSelector(IHub.issueShares.selector),
            abi.encode(uint256(0), uint128(0), uint128(0), uint128(0))
        );
        vm.mockCall(hub, abi.encodeWithSelector(IHub.approveRedeems.selector), abi.encode(uint256(0), uint128(0)));
        vm.mockCall(
            hub,
            abi.encodeWithSelector(IHub.revokeShares.selector),
            abi.encode(uint256(0), uint128(0), uint128(0), uint128(0))
        );
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
            abi.encodeWithSelector(IShareClassManager.issuance.selector, SC_1, CENTRIFUGE_ID_1),
            abi.encode(100)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, SC_1, CENTRIFUGE_ID_2),
            abi.encode(200)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowDepositEpoch.selector, SC_1, asset1),
            abi.encode(1)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowIssueEpoch.selector, SC_1, asset1),
            abi.encode(1)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowRedeemEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowRevokeEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );
    }

    function _deployManager() internal {
        priceManager = new SimplePriceManager(IHub(hub), auth);
        vm.prank(auth);
        priceManager.rely(caller);

        vm.prank(hubManager);
        priceManager.updateManager(POOL_A, manager, true);

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
    function testSetNetworksSuccess() public {
        uint16[] memory networks = new uint16[](3);
        networks[0] = CENTRIFUGE_ID_1;
        networks[1] = CENTRIFUGE_ID_2;
        networks[2] = CENTRIFUGE_ID_3;

        vm.prank(hubManager);
        priceManager.setNetworks(POOL_A, networks);

        uint16[] memory storedNetworks = priceManager.networks(POOL_A);

        assertEq(storedNetworks[0], CENTRIFUGE_ID_1);
        assertEq(storedNetworks[1], CENTRIFUGE_ID_2);
        assertEq(storedNetworks[2], CENTRIFUGE_ID_3);
    }

    function testSetNetworksUnauthorized() public {
        uint16[] memory networks = new uint16[](1);
        networks[0] = CENTRIFUGE_ID_1;

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.setNetworks(POOL_A, networks);
    }

    function testSetNetworksEmpty() public {
        uint16[] memory networks = new uint16[](0);

        vm.prank(hubManager);
        priceManager.setNetworks(POOL_A, networks);
    }

    function testUpdateManagerSuccess() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit ISimplePriceManager.UpdateManager(POOL_A, newManager, true);

        vm.prank(hubManager);
        priceManager.updateManager(POOL_A, newManager, true);

        assertTrue(priceManager.manager(POOL_A, newManager));
    }

    function testUpdateManagerRemove() public {
        address managerAddr = makeAddr("newManager");

        vm.prank(hubManager);
        priceManager.updateManager(POOL_A, managerAddr, true);
        assertTrue(priceManager.manager(POOL_A, managerAddr));

        vm.expectEmit(true, true, false, false);
        emit ISimplePriceManager.UpdateManager(POOL_A, managerAddr, false);

        vm.prank(hubManager);
        priceManager.updateManager(POOL_A, managerAddr, false);

        assertFalse(priceManager.manager(POOL_A, managerAddr));
    }

    function testUpdateManagerUnauthorized() public {
        address managerAddr = makeAddr("newManager");

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.updateManager(POOL_A, managerAddr, true);
    }
}

contract SimplePriceManagerFileTests is SimplePriceManagerTest {
    function testFileGateway() public {
        address newGateway = makeAddr("newGateway");

        vm.expectEmit(true, false, true, true);
        emit ISimplePriceManager.File("gateway", newGateway);

        vm.prank(auth);
        priceManager.file("gateway", newGateway);

        assertEq(address(priceManager.gateway()), newGateway);
    }

    function testFileUnrecognizedParam() public {
        address someAddress = makeAddr("someAddress");

        vm.expectRevert(ISimplePriceManager.FileUnrecognizedParam.selector);
        vm.prank(auth);
        priceManager.file("invalid", someAddress);
    }

    function testFileUnauthorized() public {
        address newGateway = makeAddr("newGateway");

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.file("gateway", newGateway);
    }
}

contract SimplePriceManagerOnUpdateTest is SimplePriceManagerTest {
    function setUp() public override {
        super.setUp();

        uint16[] memory networks = new uint16[](2);
        networks[0] = CENTRIFUGE_ID_1;
        networks[1] = CENTRIFUGE_ID_2;

        vm.prank(hubManager);
        priceManager.setNetworks(POOL_A, networks);
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
        emit ISimplePriceManager.Update(POOL_A, netAssetValue, 100, d18(10, 1));

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, netAssetValue);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 100);
        assertEq(globalNAV, netAssetValue);

        (uint128 networkNAV, uint128 networkIssuance) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
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
        emit ISimplePriceManager.Update(POOL_A, 2700, 300, d18(9, 1)); // total NAV=2700, total issuance=300

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
            abi.encodeWithSelector(IShareClassManager.issuance.selector, SC_1, CENTRIFUGE_ID_1),
            abi.encode(150)
        );

        uint128 newNetAssetValue = 1200;

        vm.expectEmit(true, true, true, true);
        emit ISimplePriceManager.Update(POOL_A, 1200, 150, d18(8, 1)); // 1200/150 = 8

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, newNetAssetValue);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 150);
        assertEq(globalNAV, 1200);
    }

    function testOnUpdateUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);
    }

    function testOnUpdateZeroIssuance() public {
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.issuance.selector, SC_1, CENTRIFUGE_ID_1),
            abi.encode(0)
        );

        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateSharePrice.selector, POOL_A, SC_1, d18(1, 1)));

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);

        (uint128 globalNAV, uint128 globalIssuance) = priceManager.metrics(POOL_A);
        assertEq(globalIssuance, 0);
        assertEq(globalNAV, 1000);
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
        emit ISimplePriceManager.Transfer(POOL_A, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, sharesTransferred);

        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, sharesTransferred);

        (uint128 fromNAV, uint128 fromIssuance) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (uint128 toNAV, uint128 toIssuance) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(fromIssuance, 50); // 100 - 50
        assertEq(toIssuance, 250); // 200 + 50

        // NAV should remain unchanged
        assertEq(fromNAV, 1000);
        assertEq(toNAV, 2000);
    }

    function testOnTransferUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 50);
    }

    function testOnTransferZeroShares() public {
        vm.prank(caller);
        priceManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 0);

        (, uint128 fromIssuance) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_1);
        (, uint128 toIssuance) = priceManager.networkMetrics(POOL_A, CENTRIFUGE_ID_2);

        assertEq(fromIssuance, 100);
        assertEq(toIssuance, 200);
    }
}

contract SimplePriceManagerInvestorActionsTest is SimplePriceManagerTest {
    function setUp() public override {
        super.setUp();

        vm.prank(caller);
        priceManager.onUpdate(POOL_A, SC_1, CENTRIFUGE_ID_1, 1000);
    }

    function testApproveDepositsAndIssueSharesSuccess() public {
        uint128 approvedAssetAmount = 500;
        uint128 extraGasLimit = 100000;
        D18 expectedNavPerShare = d18(10, 1); // 1000/100 = 10

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.approveDeposits.selector, POOL_A, SC_1, asset1, 1, approvedAssetAmount)
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.issueShares.selector, POOL_A, SC_1, asset1, uint32(1), expectedNavPerShare, extraGasLimit
            )
        );

        vm.prank(manager);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_1, asset1, approvedAssetAmount, extraGasLimit);
    }

    function testApproveDepositsAndIssueSharesUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_1, asset1, 500, 100000);
    }

    function testApproveDepositsAndIssueSharesMismatchedEpochs() public {
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowDepositEpoch.selector, SC_1, asset1),
            abi.encode(1)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowIssueEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );

        vm.expectRevert(ISimplePriceManager.MismatchedEpochs.selector);
        vm.prank(manager);
        priceManager.approveDepositsAndIssueShares(POOL_A, SC_1, asset1, 500, 100000);
    }

    function testApproveRedeemsAndRevokeSharesSuccess() public {
        uint128 approvedShareAmount = 50;
        uint128 extraGasLimit = 100000;

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.approveRedeems.selector, POOL_A, SC_1, asset1, uint32(2), approvedShareAmount)
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.revokeShares.selector, POOL_A, SC_1, asset1, uint32(2), d18(10, 1), extraGasLimit
            ) // 1000/100 = 10
        );

        vm.prank(manager);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_1, asset1, approvedShareAmount, extraGasLimit);
    }

    function testApproveRedeemsAndRevokeSharesUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_1, asset1, 50, 100000);
    }

    function testApproveRedeemsAndRevokeSharesMismatchedEpochs() public {
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowRedeemEpoch.selector, SC_1, asset1),
            abi.encode(2)
        );
        vm.mockCall(
            shareClassManager,
            abi.encodeWithSelector(IShareClassManager.nowRevokeEpoch.selector, SC_1, asset1),
            abi.encode(3)
        );

        vm.expectRevert(ISimplePriceManager.MismatchedEpochs.selector);
        vm.prank(manager);
        priceManager.approveRedeemsAndRevokeShares(POOL_A, SC_1, asset1, 50, 100000);
    }
}

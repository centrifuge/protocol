// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {Mock} from "../../common/mocks/Mock.sol";
import {MockValuation} from "../../common/mocks/MockValuation.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IValuation} from "../../../src/common/interfaces/IValuation.sol";
import {AssetId, newAssetId} from "../../../src/common/types/AssetId.sol";
import {AccountId, withCentrifugeId} from "../../../src/common/types/AccountId.sol";

import {IHub} from "../../../src/hub/interfaces/IHub.sol";
import {IHoldings} from "../../../src/hub/interfaces/IHoldings.sol";
import {IAccounting} from "../../../src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";

import {NAVManager, NAVManagerFactory} from "../../../src/managers/NAVManager.sol";
import {INAVManager, INAVHook} from "../../../src/managers/interfaces/INAVManager.sol";
import {INAVManagerFactory} from "../../../src/managers/interfaces/INAVManagerFactory.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract NAVManagerTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));
    uint16 constant CENTRIFUGE_ID_1 = 1;
    uint16 constant CENTRIFUGE_ID_2 = 2;

    AssetId asset1 = newAssetId(1, 1);
    AssetId asset2 = newAssetId(2, 1);

    address hub = address(new IsContract());
    address accounting = address(new IsContract());
    address holdings = address(new IsContract());
    address hubRegistry = address(new IsContract());
    INAVHook navHook = INAVHook(address(new IsContract()));

    address unauthorized = makeAddr("unauthorized");
    address manager = makeAddr("manager");
    address hubManager = makeAddr("hubManager");

    NAVManager navManager;
    MockValuation mockValuation;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();

        mockValuation = new MockValuation(IHubRegistry(hubRegistry));
        mockValuation.setPrice(POOL_A, SC_1, asset1, d18(1, 1));
    }

    function _setupMocks() internal {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.accounting.selector), abi.encode(accounting));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.holdings.selector), abi.encode(holdings));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.createAccount.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.initializeHolding.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.initializeLiability.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValuation.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.setHoldingAccountId.selector), abi.encode());

        vm.mockCall(holdings, abi.encodeWithSelector(IHoldings.snapshot.selector), abi.encode(false, uint64(0)));

        vm.mockCall(accounting, abi.encodeWithSelector(IAccounting.accountValue.selector), abi.encode(true, uint128(0)));

        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", asset1), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", asset2), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint64)", POOL_A), abi.encode(18));
        vm.mockCall(hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            hubRegistry, abi.encodeWithSelector(IHubRegistry.manager.selector, POOL_A, hubManager), abi.encode(true)
        );

        vm.mockCall(address(navHook), abi.encodeWithSelector(INAVHook.onUpdate.selector), abi.encode());
        vm.mockCall(address(navHook), abi.encodeWithSelector(INAVHook.onTransfer.selector), abi.encode());
    }

    function _deployManager() internal {
        navManager = new NAVManager(POOL_A, IHub(hub));
        vm.prank(hubManager);
        navManager.updateManager(manager, true);
    }

    function _mockAccountValue(AccountId accountId, uint128 value, bool isPositive) internal {
        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.accountValue.selector, POOL_A, accountId),
            abi.encode(isPositive, value)
        );
    }
}

contract NAVManagerConstructorTest is NAVManagerTest {
    function testConstructor() public view {
        assertEq(navManager.poolId().raw(), POOL_A.raw());
        assertEq(address(navManager.hub()), address(hub));
        assertEq(address(navManager.holdings()), holdings);
        assertEq(address(navManager.accounting()), address(accounting));
        assertEq(address(navManager.navHook()), address(0));
    }
}

contract NAVManagerConfigureTest is NAVManagerTest {
    function testSetNAVHookSuccess() public {
        vm.expectEmit(true, false, false, true);
        emit INAVManager.SetNavHook(address(navHook));

        vm.prank(hubManager);
        navManager.setNAVHook(navHook);

        assertEq(address(navManager.navHook()), address(navHook));
    }

    function testSetNAVHookUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.setNAVHook(navHook);
    }

    function testSetNAVHookToZeroAddress() public {
        vm.prank(hubManager);
        navManager.setNAVHook(INAVHook(address(0)));

        assertEq(address(navManager.navHook()), address(0));
    }

    function testUpdateManagerSuccess() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit INAVManager.UpdateManager(newManager, true);

        vm.prank(hubManager);
        navManager.updateManager(newManager, true);

        assertTrue(navManager.manager(newManager));
    }

    function testUpdateManagerRemove() public {
        address managerAddr = makeAddr("newManager");

        vm.prank(hubManager);
        navManager.updateManager(managerAddr, true);
        assertTrue(navManager.manager(managerAddr));

        vm.expectEmit(true, true, false, false);
        emit INAVManager.UpdateManager(managerAddr, false);

        vm.prank(hubManager);
        navManager.updateManager(managerAddr, false);

        assertFalse(navManager.manager(managerAddr));
    }

    function testUpdateManagerUnauthorized() public {
        address managerAddr = makeAddr("newManager");

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.updateManager(managerAddr, true);
    }

    function testUpdateManagerZeroAddress() public {
        vm.expectRevert(INAVManager.EmptyAddress.selector);
        vm.prank(hubManager);
        navManager.updateManager(address(0), true);
    }

    function testInitializeNetworkSuccess() public {
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.createAccount.selector, POOL_A, navManager.equityAccount(CENTRIFUGE_ID_1), false
            )
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.createAccount.selector, POOL_A, navManager.liabilityAccount(CENTRIFUGE_ID_1), false
            )
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, navManager.gainAccount(CENTRIFUGE_ID_1), false)
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, navManager.lossAccount(CENTRIFUGE_ID_1), false)
        );

        vm.expectEmit(true, false, false, true);
        emit INAVManager.InitializeNetwork(CENTRIFUGE_ID_1);

        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);

        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 5);
    }

    function testInitializeNetworkAlreadyInitialized() public {
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);

        vm.expectRevert(INAVManager.AlreadyInitialized.selector);
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
    }

    function testInitializeNetworkUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
    }
}

contract NAVManagerHoldingInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
    }

    function testInitializeHoldingSuccess() public {
        AccountId expectedAssetAccount = withCentrifugeId(CENTRIFUGE_ID_1, 5);

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedAssetAccount, true)
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.initializeHolding.selector,
                POOL_A,
                SC_1,
                asset1,
                mockValuation,
                expectedAssetAccount,
                navManager.equityAccount(CENTRIFUGE_ID_1),
                navManager.gainAccount(CENTRIFUGE_ID_1),
                navManager.lossAccount(CENTRIFUGE_ID_1)
            )
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.InitializeHolding(SC_1, asset1);

        vm.prank(manager);
        navManager.initializeHolding(SC_1, asset1, mockValuation);

        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 6);
        assertEq(navManager.assetAccount(CENTRIFUGE_ID_1, asset1).raw(), expectedAssetAccount.raw());
    }

    function testInitializeHoldingNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        vm.prank(manager);
        navManager.initializeHolding(SC_1, AssetId.wrap(uint128(3) << 64 | 300), mockValuation);
    }

    function testInitializeHoldingSameAssetTwice() public {
        vm.prank(manager);
        navManager.initializeHolding(SC_1, asset1, mockValuation);

        AccountId expectedAssetAccount = withCentrifugeId(CENTRIFUGE_ID_1, 5);

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedAssetAccount, true)
        );

        vm.prank(manager);
        navManager.initializeHolding(SC_2, asset1, mockValuation);

        // Account counter should increment again
        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 7);
    }

    function testInitializeHoldingUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.initializeHolding(SC_1, asset1, mockValuation);
    }
}

contract NAVManagerLiabilityInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
    }

    function testInitializeLiabilitySuccess() public {
        AccountId expectedExpenseAccount = withCentrifugeId(CENTRIFUGE_ID_1, 5);

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedExpenseAccount, true)
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.initializeLiability.selector,
                POOL_A,
                SC_1,
                asset1,
                mockValuation,
                expectedExpenseAccount,
                navManager.liabilityAccount(CENTRIFUGE_ID_1)
            )
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.InitializeLiability(SC_1, asset1);

        vm.prank(manager);
        navManager.initializeLiability(SC_1, asset1, mockValuation);

        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 6);
        assertEq(navManager.expenseAccount(CENTRIFUGE_ID_1, asset1).raw(), expectedExpenseAccount.raw());
    }

    function testInitializeLiabilityNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        vm.prank(manager);
        navManager.initializeLiability(SC_1, asset2, mockValuation);
    }

    function testInitializeLiabilityUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.initializeLiability(SC_1, asset1, mockValuation);
    }
}

contract NAVManagerOnSyncTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(hubManager);
        navManager.setNAVHook(navHook);
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
    }

    function testOnSyncSuccess() public {
        // Mock account values: equity=1000, gain=200, loss=100, liability=50
        // NAV = 1000 + 200 - 100 - 50 = 1050
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 1000, true);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 200, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 100, false);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 50, true);

        vm.expectCall(
            address(navHook), abi.encodeWithSelector(INAVHook.onUpdate.selector, POOL_A, SC_1, CENTRIFUGE_ID_1, 1050)
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.Sync(SC_1, CENTRIFUGE_ID_1, 1050);

        vm.prank(holdings);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);
    }

    function testOnSyncInvalidPoolId() public {
        vm.expectRevert(INAVManager.InvalidPoolId.selector);
        vm.prank(holdings);
        navManager.onSync(POOL_B, SC_1, CENTRIFUGE_ID_1);
    }

    function testOnSyncNotHoldings() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);
    }

    function testOnSyncNoNAVHook() public {
        // Reset NAV hook to zero
        vm.prank(hubManager);
        navManager.setNAVHook(INAVHook(address(0)));

        vm.expectRevert(INAVManager.InvalidNAVHook.selector);
        vm.prank(holdings);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);
    }
}

contract NAVManagerNetAssetValueTest is NAVManagerTest {
    function testNetAssetValueCalculation() public {
        // Mock account values: equity=1000, gain=200, loss=100, liability=50
        // Expected NAV = 1000 + 200 - 100 - 50 = 1050
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 1000, true);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 200, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 100, false);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 50, true);

        uint128 nav = navManager.netAssetValue(CENTRIFUGE_ID_1);
        assertEq(nav, 1050);
    }

    function testNetAssetValueZero() public view {
        uint128 nav = navManager.netAssetValue(CENTRIFUGE_ID_1);
        assertEq(nav, 0);
    }

    function testNetAssetValueNegative() public {
        // Mock values that result in negative NAV
        // equity=100, gain=50, loss=200, liability=100
        // NAV = 100 + 50 - 200 - 100 = -150
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 100, true);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 50, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 200, false);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 100, true);

        vm.expectRevert();
        navManager.netAssetValue(CENTRIFUGE_ID_1);
    }
}

contract NAVManagerUpdateHoldingTest is NAVManagerTest {
    function testUpdateHoldingValue() public {
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        vm.prank(manager);
        navManager.updateHoldingValue(SC_1, asset1);
    }

    function testUpdateHoldingValueUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.updateHoldingValue(SC_1, asset1);
    }

    function testUpdateHoldingValuation() public {
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateHoldingValuation.selector, POOL_A, SC_1, asset1, mockValuation)
        );
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        vm.prank(manager);
        navManager.updateHoldingValuation(SC_1, asset1, mockValuation);
    }

    function testUpdateHoldingValuationUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.updateHoldingValuation(SC_1, asset1, mockValuation);
    }

    function testSetHoldingAccountId() public {
        AccountId accountId = withCentrifugeId(CENTRIFUGE_ID_1, 10);
        uint8 kind = 1;

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.setHoldingAccountId.selector, POOL_A, SC_1, asset1, kind, accountId)
        );

        vm.prank(manager);
        navManager.setHoldingAccountId(SC_1, asset1, kind, accountId);
    }

    function testSetHoldingAccountIdUnauthorized() public {
        AccountId accountId = withCentrifugeId(CENTRIFUGE_ID_1, 10);
        uint8 kind = 1;

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.setHoldingAccountId(SC_1, asset1, kind, accountId);
    }
}

contract NAVManagerHelperFunctionsTest is NAVManagerTest {
    function testEquityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 1);
        AccountId actual = navManager.equityAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testLiabilityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 2);
        AccountId actual = navManager.liabilityAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testGainAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 3);
        AccountId actual = navManager.gainAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testLossAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 4);
        AccountId actual = navManager.lossAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testAssetAccount() public {
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
        vm.prank(manager);
        navManager.initializeHolding(SC_1, asset1, mockValuation);

        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 5);
        AccountId actual = navManager.assetAccount(CENTRIFUGE_ID_1, asset1);
        assertEq(actual.raw(), expected.raw());
    }

    function testExpenseAccount() public {
        vm.prank(manager);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
        vm.prank(manager);
        navManager.initializeLiability(SC_1, asset1, mockValuation);

        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 5);
        AccountId actual = navManager.expenseAccount(CENTRIFUGE_ID_1, asset1);
        assertEq(actual.raw(), expected.raw());
    }

    function testAssetAccountNotInitialized() public view {
        AccountId actual = navManager.assetAccount(CENTRIFUGE_ID_1, asset1);
        assertTrue(actual.isNull());
    }
}

contract NAVManagerOnTransferTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(hubManager);
        navManager.setNAVHook(navHook);
    }

    function testOnTransferBasicAuth() public {
        vm.expectRevert(INAVManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferInvalidPoolId() public {
        vm.expectRevert(INAVManager.InvalidPoolId.selector);
        vm.prank(hub);
        navManager.onTransfer(POOL_B, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferNoNAVHook() public {
        vm.prank(hubManager);
        navManager.setNAVHook(INAVHook(address(0)));

        vm.expectRevert(INAVManager.InvalidNAVHook.selector);
        vm.prank(hub);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferSuccess() public {
        vm.expectCall(
            address(navHook),
            abi.encodeWithSelector(INAVHook.onTransfer.selector, POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1)
        );

        vm.expectEmit(true, true, true, true);
        emit INAVManager.Transfer(SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);

        vm.prank(hub);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }
}

contract NAVManagerFactoryTest is Test {
    address hub = address(new IsContract());
    address accounting = address(new IsContract());
    address holdings = address(new IsContract());
    address hubRegistry = address(new IsContract());

    NAVManagerFactory factory;

    function setUp() public {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.accounting.selector), abi.encode(accounting));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.holdings.selector), abi.encode(holdings));
        factory = new NAVManagerFactory(IHub(hub));
    }

    function testFactoryConstructor() public view {
        assertEq(address(factory.hub()), address(hub));
    }

    function testNewManagerSuccess() public {
        PoolId poolId = PoolId.wrap(1);

        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(IHubRegistry.exists.selector, poolId), abi.encode(true)
        );

        vm.expectEmit(true, false, false, false);
        emit INAVManagerFactory.DeployNavManager(poolId, address(0));

        INAVManager manager = factory.newManager(poolId);

        assertTrue(address(manager) != address(0));
        assertEq(NAVManager(address(manager)).poolId().raw(), poolId.raw());
    }

    function testNewManagerInvalidPool() public {
        PoolId poolId = PoolId.wrap(1);

        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(IHubRegistry.exists.selector, poolId), abi.encode(false)
        );

        vm.expectRevert(INAVManagerFactory.InvalidPoolId.selector);
        factory.newManager(poolId);
    }
}

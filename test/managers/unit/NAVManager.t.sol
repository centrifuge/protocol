// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {D18, d18} from "../../../src/misc/types/D18.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId, newAssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {AccountId, withCentrifugeId} from "../../../src/common/types/AccountId.sol";
import {IValuation} from "../../../src/common/interfaces/IValuation.sol";

import {NAVManager, NavManagerFactory} from "../../../src/managers/NAVManager.sol";
import {INAVManager, INAVHook} from "../../../src/managers/interfaces/INAVManager.sol";
import {INAVManagerFactory} from "../../../src/managers/interfaces/INAVManagerFactory.sol";

import {IHub} from "../../../src/hub/interfaces/IHub.sol";
import {IAccounting} from "../../../src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";

import {MockValuation} from "../../common/mocks/MockValuation.sol";
import {Mock} from "../../common/mocks/Mock.sol";

import "forge-std/Test.sol";

// Mock contracts to bypass foundry mockCall issues
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

    address deployer = address(this);
    address contractUpdater = makeAddr("contractUpdater");
    address unauthorized = makeAddr("unauthorized");
    address manager = makeAddr("manager");

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

        vm.mockCall(accounting, abi.encodeWithSelector(IAccounting.accountValue.selector), abi.encode(true, uint128(0)));

        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", asset1), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", asset2), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint64)", POOL_A), abi.encode(18));

        vm.mockCall(address(navHook), abi.encodeWithSelector(INAVHook.onUpdate.selector), abi.encode());
        vm.mockCall(address(navHook), abi.encodeWithSelector(INAVHook.onTransfer.selector), abi.encode());
    }

    function _deployManager() internal {
        vm.prank(deployer);
        navManager = new NAVManager(POOL_A, IHub(hub), deployer);
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
        assertEq(PoolId.unwrap(navManager.poolId()), PoolId.unwrap(POOL_A));
        assertEq(address(navManager.hub()), address(hub));
        assertEq(navManager.holdings(), holdings);
        assertEq(address(navManager.accounting()), address(accounting));
        assertEq(address(navManager.navHook()), address(0));
    }
}

contract NAVManagerConfigureTest is NAVManagerTest {
    function testSetNAVHookSuccess() public {
        vm.prank(deployer);
        navManager.setNAVHook(navHook);

        assertEq(address(navManager.navHook()), address(navHook));
    }

    function testSetNAVHookUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.setNAVHook(navHook);
    }

    function testSetNAVHookToZeroAddress() public {
        vm.prank(deployer);
        navManager.setNAVHook(INAVHook(address(0)));

        assertEq(address(navManager.navHook()), address(0));
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

        navManager.initializeNetwork(CENTRIFUGE_ID_1);

        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 5);
    }

    function testInitializeNetworkAlreadyInitialized() public {
        navManager.initializeNetwork(CENTRIFUGE_ID_1);

        vm.expectRevert(INAVManager.AlreadyInitialized.selector);
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
    }
}

contract NAVManagerHoldingInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        // Initialize network first
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

        navManager.initializeHolding(SC_1, asset1, mockValuation);

        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 6);
        assertEq(
            AccountId.unwrap(navManager.assetAccount(CENTRIFUGE_ID_1, asset1)), AccountId.unwrap(expectedAssetAccount)
        );
    }

    function testInitializeHoldingNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        navManager.initializeHolding(SC_1, AssetId.wrap(uint128(3) << 64 | 300), mockValuation);
    }

    function testInitializeHoldingSameAssetTwice() public {
        navManager.initializeHolding(SC_1, asset1, mockValuation);

        // Should reuse the same account
        AccountId expectedAssetAccount = withCentrifugeId(CENTRIFUGE_ID_1, 5);

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedAssetAccount, true)
        );

        navManager.initializeHolding(SC_2, asset1, mockValuation);

        // Account counter should increment again
        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 7);
    }
}

contract NAVManagerLiabilityInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
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

        navManager.initializeLiability(SC_1, asset1, mockValuation);

        assertEq(navManager.accountCounter(CENTRIFUGE_ID_1), 6);
        assertEq(
            AccountId.unwrap(navManager.expenseAccount(CENTRIFUGE_ID_1, asset1)),
            AccountId.unwrap(expectedExpenseAccount)
        );
    }

    function testInitializeLiabilityNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        navManager.initializeLiability(SC_1, asset2, mockValuation);
    }
}

contract NAVManagerOnSyncTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
        navManager.setNAVHook(navHook);
    }

    function testOnSyncSuccess() public {
        // Mock account values: equity=1000, gain=200, loss=100, liability=50
        // NAV = 1000 + 200 - 100 - 50 = 1050
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 1000, true);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 200, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 100, false);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 50, true);

        vm.expectCall(
            address(navHook),
            abi.encodeWithSelector(INAVHook.onUpdate.selector, POOL_A, SC_1, CENTRIFUGE_ID_1, d18(1050))
        );

        vm.prank(holdings);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);

        // assertEq(mockNAVHook.updateCallCount(), 1);
        // assertEq(PoolId.unwrap(mockNAVHook.lastPoolId()), PoolId.unwrap(POOL_A));
        // assertEq(ShareClassId.unwrap(mockNAVHook.lastScId()), ShareClassId.unwrap(SC_1));
        // assertEq(mockNAVHook.lastCentrifugeId(), CENTRIFUGE_ID_1);
        // assertEq(mockNAVHook.lastNetAssetValue().raw(), d18(1050).raw());
    }

    function testOnSyncInvalidPoolId() public {
        vm.expectRevert();
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
        vm.prank(deployer);
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
        uint128 nav = navManager.netAssetValue(CENTRIFUGE_ID_1);
    }
}

contract NAVManagerUpdateHoldingTest is NAVManagerTest {
    function testUpdateHoldingValue() public {
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        navManager.updateHoldingValue(SC_1, asset1);
    }

    function testUpdateHoldingValuation() public {
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateHoldingValuation.selector, POOL_A, SC_1, asset1, mockValuation)
        );

        navManager.updateHoldingValuation(SC_1, asset1, mockValuation);
    }

    function testSetHoldingAccountId() public {
        AccountId accountId = withCentrifugeId(CENTRIFUGE_ID_1, 10);
        uint8 kind = 1;

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.setHoldingAccountId.selector, POOL_A, SC_1, asset1, kind, accountId)
        );

        navManager.setHoldingAccountId(SC_1, asset1, kind, accountId);
    }
}

contract NAVManagerHelperFunctionsTest is NAVManagerTest {
    function testEquityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 1);
        AccountId actual = navManager.equityAccount(CENTRIFUGE_ID_1);
        assertEq(AccountId.unwrap(actual), AccountId.unwrap(expected));
    }

    function testLiabilityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 2);
        AccountId actual = navManager.liabilityAccount(CENTRIFUGE_ID_1);
        assertEq(AccountId.unwrap(actual), AccountId.unwrap(expected));
    }

    function testGainAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 3);
        AccountId actual = navManager.gainAccount(CENTRIFUGE_ID_1);
        assertEq(AccountId.unwrap(actual), AccountId.unwrap(expected));
    }

    function testLossAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 4);
        AccountId actual = navManager.lossAccount(CENTRIFUGE_ID_1);
        assertEq(AccountId.unwrap(actual), AccountId.unwrap(expected));
    }

    function testAssetAccount() public {
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
        navManager.initializeHolding(SC_1, asset1, mockValuation);

        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 5);
        AccountId actual = navManager.assetAccount(CENTRIFUGE_ID_1, asset1);
        assertEq(AccountId.unwrap(actual), AccountId.unwrap(expected));
    }

    function testExpenseAccount() public {
        navManager.initializeNetwork(CENTRIFUGE_ID_1);
        navManager.initializeLiability(SC_1, asset1, mockValuation);

        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, 5);
        AccountId actual = navManager.expenseAccount(CENTRIFUGE_ID_1, asset1);
        assertEq(AccountId.unwrap(actual), AccountId.unwrap(expected));
    }

    function testAssetAccountNotInitialized() public view {
        AccountId actual = navManager.assetAccount(CENTRIFUGE_ID_1, asset1);
        assertTrue(actual.isNull());
    }
}

contract NAVManagerOnTransferTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        navManager.setNAVHook(navHook);
    }

    function testOnTransferBasicAuth() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferInvalidPoolId() public {
        vm.expectRevert();
        vm.prank(hub);
        navManager.onTransfer(POOL_B, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferNoNAVHook() public {
        vm.prank(deployer);
        navManager.setNAVHook(INAVHook(address(0)));

        vm.expectRevert(INAVManager.InvalidNAVHook.selector);
        vm.prank(hub);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferSuccess() public {
        vm.expectCall(
            address(navHook),
            abi.encodeWithSelector(INAVHook.onTransfer.selector, POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, d18(1))
        );

        vm.prank(hub);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }
}

contract NAVManagerFactoryTest is Test {
    address hub = address(new IsContract());
    address accounting = address(new IsContract());
    address holdings = address(new IsContract());
    address hubRegistry = address(new IsContract());
    address contractUpdater = makeAddr("contractUpdater");

    NavManagerFactory factory;

    function setUp() public {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.accounting.selector), abi.encode(accounting));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.holdings.selector), abi.encode(holdings));
        factory = new NavManagerFactory(contractUpdater, IHub(hub));
    }

    function testFactoryConstructor() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.hub()), address(hub));
    }

    function testNewManagerSuccess() public {
        PoolId poolId = PoolId.wrap(1);

        // Mock hubRegistry.exists() to return true
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(IHubRegistry.exists.selector, poolId), abi.encode(true)
        );

        vm.expectEmit(true, false, false, false);
        emit INAVManagerFactory.DeployNavManager(poolId, address(0)); // address will be different

        INAVManager manager = factory.newManager(poolId);

        assertTrue(address(manager) != address(0));
        assertEq(PoolId.unwrap(NAVManager(address(manager)).poolId()), PoolId.unwrap(poolId));
    }

    function testNewManagerInvalidPool() public {
        PoolId poolId = PoolId.wrap(1);

        // Mock hubRegistry.exists() to return false
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(IHubRegistry.exists.selector, poolId), abi.encode(false)
        );

        vm.expectRevert(INAVManagerFactory.InvalidPoolId.selector);
        factory.newManager(poolId);
    }
}

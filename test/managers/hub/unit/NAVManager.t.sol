// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {Mock} from "../../../core/mocks/Mock.sol";
import {MockValuation} from "../../../core/mocks/MockValuation.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IHub, AccountType} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IAccounting, JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {AccountId, withCentrifugeId, withAssetId} from "../../../../src/core/types/AccountId.sol";

import {NAVManager} from "../../../../src/managers/hub/NAVManager.sol";
import {INAVManager, INAVHook} from "../../../../src/managers/hub/interfaces/INAVManager.sol";

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
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateJournal.selector), abi.encode());

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
        navManager = new NAVManager(IHub(hub), address(this));
        navManager.rely(hub);
        navManager.rely(holdings);

        vm.prank(hubManager);
        navManager.updateManager(POOL_A, manager, true);
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
        assertEq(address(navManager.hub()), address(hub));
        assertEq(address(navManager.holdings()), holdings);
        assertEq(address(navManager.accounting()), address(accounting));
    }
}

contract NAVManagerConfigureTest is NAVManagerTest {
    function testSetNAVHookSuccess() public {
        vm.expectEmit(true, false, false, true);
        emit INAVManager.SetNavHook(POOL_A, address(navHook));

        vm.prank(hubManager);
        navManager.setNAVHook(POOL_A, navHook);

        assertEq(address(navManager.navHook(POOL_A)), address(navHook));
        assertEq(address(navManager.navHook(POOL_B)), address(0));
    }

    function testSetNAVHookUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.setNAVHook(POOL_A, navHook);
    }

    function testSetNAVHookToZeroAddress() public {
        vm.prank(hubManager);
        navManager.setNAVHook(POOL_A, INAVHook(address(0)));

        assertEq(address(navManager.navHook(POOL_A)), address(0));
    }

    function testUpdateManagerSuccess() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit INAVManager.UpdateManager(POOL_A, newManager, true);

        vm.prank(hubManager);
        navManager.updateManager(POOL_A, newManager, true);

        assertTrue(navManager.manager(POOL_A, newManager));
    }

    function testUpdateManagerRemove() public {
        address managerAddr = makeAddr("newManager");

        vm.prank(hubManager);
        navManager.updateManager(POOL_A, managerAddr, true);
        assertTrue(navManager.manager(POOL_A, managerAddr));

        vm.expectEmit(true, true, false, false);
        emit INAVManager.UpdateManager(POOL_A, managerAddr, false);

        vm.prank(hubManager);
        navManager.updateManager(POOL_A, managerAddr, false);

        assertFalse(navManager.manager(POOL_A, managerAddr));
    }

    function testUpdateManagerUnauthorized() public {
        address managerAddr = makeAddr("newManager");

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.updateManager(POOL_A, managerAddr, true);
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
            abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, navManager.lossAccount(CENTRIFUGE_ID_1), true)
        );

        vm.expectEmit(true, false, false, true);
        emit INAVManager.InitializeNetwork(POOL_A, CENTRIFUGE_ID_1);

        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);

        assertTrue(navManager.initialized(POOL_A, CENTRIFUGE_ID_1));
    }

    function testInitializeNetworkAlreadyInitialized() public {
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);

        vm.expectRevert(INAVManager.AlreadyInitialized.selector);
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testInitializeNetworkUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }
}

contract NAVManagerHoldingInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testInitializeHoldingSuccess() public {
        AccountId expectedAssetAccount = withAssetId(asset1, uint16(AccountType.Asset));

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
        emit INAVManager.InitializeHolding(POOL_A, SC_1, asset1);

        vm.prank(manager);
        navManager.initializeHolding(POOL_A, SC_1, asset1, mockValuation);

        assertEq(navManager.assetAccount(asset1).raw(), expectedAssetAccount.raw());
    }

    function testInitializeHoldingNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        vm.prank(manager);
        navManager.initializeHolding(POOL_A, SC_1, AssetId.wrap(uint128(3) << 64 | 300), mockValuation);
    }

    function testInitializeHoldingSameAssetTwice() public {
        vm.prank(manager);
        navManager.initializeHolding(POOL_A, SC_1, asset1, mockValuation);

        AccountId expectedAssetAccount = withAssetId(asset1, uint16(AccountType.Asset));

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedAssetAccount, true)
        );

        vm.prank(manager);
        navManager.initializeHolding(POOL_A, SC_2, asset1, mockValuation);

        assertEq(navManager.assetAccount(asset1).raw(), expectedAssetAccount.raw());
    }

    function testInitializeHoldingUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.initializeHolding(POOL_A, SC_1, asset1, mockValuation);
    }
}

contract NAVManagerLiabilityInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testInitializeLiabilitySuccess() public {
        AccountId expectedExpenseAccount = withAssetId(asset1, uint16(AccountType.Expense));

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
        emit INAVManager.InitializeLiability(POOL_A, SC_1, asset1);

        vm.prank(manager);
        navManager.initializeLiability(POOL_A, SC_1, asset1, mockValuation);

        assertEq(navManager.expenseAccount(asset1).raw(), expectedExpenseAccount.raw());
    }

    function testInitializeLiabilityNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        vm.prank(manager);
        navManager.initializeLiability(POOL_A, SC_1, asset2, mockValuation);
    }

    function testInitializeLiabilityUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.initializeLiability(POOL_A, SC_1, asset1, mockValuation);
    }
}

contract NAVManagerOnSyncTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(hubManager);
        navManager.setNAVHook(POOL_A, navHook);
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testOnSyncSuccess() public {
        // Mock account values: equity=1000, gain=200, loss=100, liability=50
        // NAV = 1000 + 200 - 100 - 50 = 1050
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 1000, true);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 200, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 100, true);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 50, true);

        vm.expectCall(
            address(navHook), abi.encodeWithSelector(INAVHook.onUpdate.selector, POOL_A, SC_1, CENTRIFUGE_ID_1, 1050)
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.Sync(POOL_A, SC_1, CENTRIFUGE_ID_1, 1050);

        vm.prank(holdings);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);
    }

    function testOnSyncNotAuthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);
    }

    function testOnSyncNoNAVHook() public {
        // Reset NAV hook to zero
        vm.prank(hubManager);
        navManager.setNAVHook(POOL_A, INAVHook(address(0)));

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
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 100, true);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 50, true);

        uint128 nav = navManager.netAssetValue(POOL_A, CENTRIFUGE_ID_1);
        assertEq(nav, 1050);
    }

    function testNetAssetValueZero() public view {
        uint128 nav = navManager.netAssetValue(POOL_A, CENTRIFUGE_ID_1);
        assertEq(nav, 0);
    }

    function testNetAssetValueZeroWhenNegative() public {
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 500, true);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 100, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 50, true);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 600, true);

        uint128 nav = navManager.netAssetValue(POOL_A, CENTRIFUGE_ID_1);
        assertEq(nav, 0);
    }

    function testNetAssetValueInvalid(
        bool equityIsPositive,
        bool gainIsPositive,
        bool lossIsPositive,
        bool liabilityIsPositive
    ) public {
        vm.assume(!equityIsPositive || !gainIsPositive || !lossIsPositive || !liabilityIsPositive);
        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), 100, equityIsPositive);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 100, gainIsPositive);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 50, lossIsPositive);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), 50, liabilityIsPositive);

        vm.expectRevert(INAVManager.InvalidNAV.selector);
        navManager.netAssetValue(POOL_A, CENTRIFUGE_ID_1);
    }
}

contract NAVManagerUpdateHoldingTest is NAVManagerTest {
    function testUpdateHoldingValue() public {
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        vm.prank(manager);
        navManager.updateHoldingValue(POOL_A, SC_1, asset1);
    }

    function testUpdateHoldingValuation() public {
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateHoldingValuation.selector, POOL_A, SC_1, asset1, mockValuation)
        );
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        vm.prank(manager);
        navManager.updateHoldingValuation(POOL_A, SC_1, asset1, mockValuation);
    }

    function testUpdateHoldingValuationUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.updateHoldingValuation(POOL_A, SC_1, asset1, mockValuation);
    }
}

contract NAVManagerCloseGainLossTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossSuccess() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 100, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 50, true);

        JournalEntry[] memory debits = new JournalEntry[](2);
        debits[0] = JournalEntry({value: 100, accountId: navManager.gainAccount(CENTRIFUGE_ID_1)});
        debits[1] = JournalEntry({value: 50, accountId: navManager.equityAccount(CENTRIFUGE_ID_1)});

        JournalEntry[] memory credits = new JournalEntry[](2);
        credits[0] = JournalEntry({value: 100, accountId: navManager.equityAccount(CENTRIFUGE_ID_1)});
        credits[1] = JournalEntry({value: 50, accountId: navManager.lossAccount(CENTRIFUGE_ID_1)});

        vm.expectCall(address(hub), abi.encodeCall(IHub.updateJournal, (POOL_A, debits, credits)));

        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossOnlyGain() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 200, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 0, true);

        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: 200, accountId: navManager.gainAccount(CENTRIFUGE_ID_1)});

        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: 200, accountId: navManager.equityAccount(CENTRIFUGE_ID_1)});

        vm.expectCall(address(hub), abi.encodeCall(IHub.updateJournal, (POOL_A, debits, credits)));

        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossOnlyLoss() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 0, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 150, true);

        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: 150, accountId: navManager.equityAccount(CENTRIFUGE_ID_1)});

        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: 150, accountId: navManager.lossAccount(CENTRIFUGE_ID_1)});

        vm.expectCall(address(hub), abi.encodeCall(IHub.updateJournal, (POOL_A, debits, credits)));

        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossNoGainNoLoss() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 0, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 0, true);

        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateJournal.selector), 0);

        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CENTRIFUGE_ID_2);
    }

    function testCloseGainLossUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }
}

contract NAVManagerHelperFunctionsTest is NAVManagerTest {
    function testEquityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(AccountType.Equity));
        AccountId actual = navManager.equityAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testLiabilityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(AccountType.Liability));
        AccountId actual = navManager.liabilityAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testGainAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(AccountType.Gain));
        AccountId actual = navManager.gainAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testLossAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(AccountType.Loss));
        AccountId actual = navManager.lossAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testAssetAccount() public {
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
        vm.prank(manager);
        navManager.initializeHolding(POOL_A, SC_1, asset1, mockValuation);

        AccountId expected = withAssetId(asset1, uint16(AccountType.Asset));
        AccountId actual = navManager.assetAccount(asset1);
        assertEq(actual.raw(), expected.raw());
    }

    function testExpenseAccount() public {
        vm.prank(manager);
        navManager.initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
        vm.prank(manager);
        navManager.initializeLiability(POOL_A, SC_1, asset1, mockValuation);

        AccountId expected = withAssetId(asset1, uint16(AccountType.Expense));
        AccountId actual = navManager.expenseAccount(asset1);
        assertEq(actual.raw(), expected.raw());
    }
}

contract NAVManagerOnTransferTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        vm.prank(hubManager);
        navManager.setNAVHook(POOL_A, navHook);
    }

    function testOnTransferUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferNoNAVHook() public {
        vm.prank(hubManager);
        navManager.setNAVHook(POOL_A, INAVHook(address(0)));

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
        emit INAVManager.Transfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);

        vm.prank(hub);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }
}

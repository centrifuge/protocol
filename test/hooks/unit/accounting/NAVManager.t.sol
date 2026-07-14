// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";

import {MockValuation} from "../../../core/mocks/MockValuation.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IValuation} from "../../../../src/core/hub/interfaces/IValuation.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromSpoke} from "../../../../src/core/utils/interfaces/IManagerCall.sol";
import {IAccounting, JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {AccountId, withCentrifugeId, withAssetId} from "../../../../src/core/types/AccountId.sol";

import {NAVManager} from "../../../../src/hooks/accounting/NAVManager.sol";
import {NAVAccount, INAVManager, INAVHook} from "../../../../src/hooks/accounting/interfaces/INAVManager.sol";

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
    address envoy = makeAddr("envoy");

    NAVManager navManager;
    MockValuation mockValuation;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();

        mockValuation = new MockValuation(IHubRegistry(hubRegistry));
        mockValuation.setPrice(POOL_A, SC_1, asset1, d18(1, 1));

        _setDefaultValuation(POOL_A, mockValuation);
    }

    function _setupMocks() internal {
        vm.mockCall(hub, abi.encodeWithSelector(IHub.accounting.selector), abi.encode(accounting));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.holdings.selector), abi.encode(holdings));
        vm.mockCall(hub, abi.encodeWithSelector(IHub.createAccount.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.initializeHolding.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValue.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateHoldingValuation.selector), abi.encode());
        vm.mockCall(hub, abi.encodeWithSelector(IHub.updateJournal.selector), abi.encode());

        vm.mockCall(holdings, abi.encodeWithSelector(IHoldings.snapshot.selector), abi.encode(false, uint64(0)));

        vm.mockCall(accounting, abi.encodeWithSelector(IAccounting.accountValue.selector), abi.encode(true, uint128(0)));

        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", asset1), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint128)", asset2), abi.encode(6));
        vm.mockCall(hubRegistry, abi.encodeWithSignature("decimals(uint64)", POOL_A), abi.encode(18));

        vm.mockCall(address(navHook), abi.encodeWithSelector(INAVHook.onUpdate.selector), abi.encode());
        vm.mockCall(address(navHook), abi.encodeWithSelector(INAVHook.onTransfer.selector), abi.encode());
    }

    function _deployManager() internal {
        navManager = new NAVManager(IHub(hub), envoy);
    }

    function _mockAccountValue(AccountId accountId, uint128 value, bool isPositive) internal {
        vm.mockCall(
            address(accounting),
            abi.encodeWithSelector(IAccounting.accountValue.selector, POOL_A, accountId),
            abi.encode(isPositive, value)
        );
    }

    //----------------------------------------------------------------------------------------------
    // ManagerCall helpers: drive privileged actions through `fromHub` as the dispatcher would.
    //----------------------------------------------------------------------------------------------

    function _setNAVHook(PoolId poolId, INAVHook hook) internal {
        vm.prank(envoy);
        navManager.fromHub(poolId, abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), address(hook)));
    }

    function _initializeNetwork(PoolId poolId, uint16 centrifugeId) internal {
        vm.prank(envoy);
        navManager.fromHub(poolId, abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), centrifugeId));
    }

    function _setDefaultValuation(PoolId poolId, IValuation valuation) internal {
        vm.prank(envoy);
        navManager.fromHub(poolId, abi.encode(uint8(INAVManager.ManagerCall.SetDefaultValuation), address(valuation)));
    }

    // The valuation is fixed per-pool via `_setDefaultValuation` (done in setUp), so it is no longer
    // passed per init; the trailing arg is kept for call-site readability.
    function _initializeHolding(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation) internal {
        vm.prank(envoy);
        navManager.fromHub(poolId, abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, assetId));
    }

    function _initializeLiability(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation) internal {
        vm.prank(envoy);
        navManager.fromHub(poolId, abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), scId, assetId));
    }

    function _updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation) internal {
        vm.prank(envoy);
        navManager.fromHub(
            poolId, abi.encode(uint8(INAVManager.ManagerCall.UpdateHoldingValuation), scId, assetId, address(valuation))
        );
    }

    function _closeGainLoss(PoolId poolId, uint16 centrifugeId) internal {
        vm.prank(envoy);
        navManager.fromHub(poolId, abi.encode(uint8(INAVManager.ManagerCall.CloseGainLoss), centrifugeId));
    }

    function _expectedHoldingAccounts(AccountId asset, AccountId equity, AccountId gain, AccountId loss)
        internal
        pure
        returns (AccountId[4] memory accounts)
    {
        accounts[0] = asset;
        accounts[1] = equity;
        accounts[2] = gain;
        accounts[3] = loss;
    }

    function _expectedLiabilityAccounts(AccountId expense, AccountId liability)
        internal
        pure
        returns (AccountId[4] memory accounts)
    {
        accounts[0] = expense;
        accounts[1] = liability;
        accounts[2] = liability;
        accounts[3] = liability;
    }
}

contract NAVManagerConstructorTest is NAVManagerTest {
    function testConstructor() public view {
        assertEq(address(navManager.hub()), address(hub));
        assertEq(address(navManager.holdings()), holdings);
        assertEq(address(navManager.accounting()), address(accounting));
        assertEq(navManager.envoy(), envoy);
    }
}

contract NAVManagerFromHubGateTest is NAVManagerTest {
    function testFromHubNotDispatcher() public {
        bytes memory payload = abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), CENTRIFUGE_ID_1);

        vm.expectRevert(INAVManager.NotEnvoy.selector);
        vm.prank(unauthorized);
        navManager.fromHub(POOL_A, payload);
    }

    function testFromHubUnexpectedValue() public {
        bytes memory payload = abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), CENTRIFUGE_ID_1);

        vm.deal(envoy, 1 ether);
        vm.expectRevert(INAVManager.UnexpectedValue.selector);
        vm.prank(envoy);
        navManager.fromHub{value: 1}(POOL_A, payload);
    }

    /// @dev Direction boundary: the NAVManager is a hub-only target — it implements
    ///      `IManagerCallFromHub.fromHub` ONLY, never `IManagerCallFromSpoke.fromSpoke`. So the untrusted
    ///      spoke path (`Envoy.callFromSpoke` -> `target.fromSpoke`) can never reach it (nonexistent
    ///      selector). Freezes the guarantee on the real contract; adding `fromSpoke` later trips this.
    function testFromSpokeUnreachable() public {
        bytes memory payload = abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), CENTRIFUGE_ID_1);
        vm.prank(envoy);
        vm.expectRevert();
        IManagerCallFromSpoke(address(navManager)).fromSpoke(POOL_A, payload, 0, bytes32(0));
    }
}

contract NAVManagerConfigureTest is NAVManagerTest {
    function testSetNAVHookSuccess() public {
        vm.expectEmit(true, false, false, true);
        emit INAVManager.SetNavHook(POOL_A, address(navHook));

        _setNAVHook(POOL_A, navHook);

        assertEq(address(navManager.navHook(POOL_A)), address(navHook));
        assertEq(address(navManager.navHook(POOL_B)), address(0));
    }

    function testSetNAVHookToZeroAddress() public {
        _setNAVHook(POOL_A, INAVHook(address(0)));

        assertEq(address(navManager.navHook(POOL_A)), address(0));
    }

    function testSetDefaultValuationSuccess() public {
        assertEq(address(navManager.defaultValuation(POOL_B)), address(0));

        vm.expectEmit(true, true, false, false);
        emit INAVManager.SetDefaultValuation(POOL_B, mockValuation);
        _setDefaultValuation(POOL_B, mockValuation);

        assertEq(address(navManager.defaultValuation(POOL_B)), address(mockValuation));
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

        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);

        assertTrue(navManager.initialized(POOL_A, CENTRIFUGE_ID_1));
    }

    function testInitializeNetworkAlreadyInitialized() public {
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);

        vm.expectRevert(INAVManager.AlreadyInitialized.selector);
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }
}

contract NAVManagerHoldingInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testInitializeHoldingSuccess() public {
        AccountId expectedAssetAccount = withAssetId(asset1, uint16(NAVAccount.Asset));

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
                _expectedHoldingAccounts(
                    expectedAssetAccount,
                    navManager.equityAccount(CENTRIFUGE_ID_1),
                    navManager.gainAccount(CENTRIFUGE_ID_1),
                    navManager.lossAccount(CENTRIFUGE_ID_1)
                )
            )
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.InitializeHolding(POOL_A, SC_1, asset1);

        _initializeHolding(POOL_A, SC_1, asset1, mockValuation);

        assertEq(navManager.assetAccount(asset1).raw(), expectedAssetAccount.raw());
    }

    function testInitializeHoldingNotInitialized() public {
        vm.prank(envoy);
        vm.expectRevert(INAVManager.NotInitialized.selector);
        navManager.fromHub(
            POOL_A,
            abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, AssetId.wrap(uint128(3) << 64 | 300))
        );
    }

    function testInitializeHoldingValuationNotSet() public {
        // POOL_B has no default valuation set (only POOL_A does, in setUp), so init must revert.
        _initializeNetwork(POOL_B, CENTRIFUGE_ID_1);

        vm.prank(envoy);
        vm.expectRevert(INAVManager.ValuationNotSet.selector);
        navManager.fromHub(POOL_B, abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, asset1));
    }

    function testInitializeHoldingSameAssetTwice() public {
        _initializeHolding(POOL_A, SC_1, asset1, mockValuation);

        AccountId expectedAssetAccount = withAssetId(asset1, uint16(NAVAccount.Asset));

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedAssetAccount, true)
        );

        _initializeHolding(POOL_A, SC_2, asset1, mockValuation);

        assertEq(navManager.assetAccount(asset1).raw(), expectedAssetAccount.raw());
    }
}

contract NAVManagerFromSpokeTest is NAVManagerTest {
    bytes32 constant SPOKE_MANAGER = bytes32("spokeManager");

    function setUp() public override {
        super.setUp();
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function _allowManager(bytes32 who, bool canManage) internal {
        vm.prank(envoy);
        navManager.fromHub(
            POOL_A, abi.encode(uint8(INAVManager.ManagerCall.UpdateManager), CENTRIFUGE_ID_1, who, canManage)
        );
    }

    function _initHoldingPayload() internal view returns (bytes memory) {
        return abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, asset1);
    }

    function _initLiabilityPayload() internal view returns (bytes memory) {
        return abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), SC_1, asset1);
    }

    function testUpdateManagerSetsAllowlist() public {
        assertFalse(navManager.manager(POOL_A, CENTRIFUGE_ID_1, SPOKE_MANAGER));

        vm.expectEmit();
        emit INAVManager.UpdateManager(POOL_A, CENTRIFUGE_ID_1, SPOKE_MANAGER, true);
        _allowManager(SPOKE_MANAGER, true);

        assertTrue(navManager.manager(POOL_A, CENTRIFUGE_ID_1, SPOKE_MANAGER));
    }

    function testFromSpokeInitializeHolding() public {
        _allowManager(SPOKE_MANAGER, true);

        AccountId expectedAssetAccount = withAssetId(asset1, uint16(NAVAccount.Asset));
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.initializeHolding.selector,
                POOL_A,
                SC_1,
                asset1,
                mockValuation,
                _expectedHoldingAccounts(
                    expectedAssetAccount,
                    navManager.equityAccount(CENTRIFUGE_ID_1),
                    navManager.gainAccount(CENTRIFUGE_ID_1),
                    navManager.lossAccount(CENTRIFUGE_ID_1)
                )
            )
        );

        vm.prank(envoy);
        navManager.fromSpoke(POOL_A, _initHoldingPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    function testFromSpokeInitializeLiability() public {
        _allowManager(SPOKE_MANAGER, true);

        AccountId expectedExpenseAccount = withAssetId(asset1, uint16(NAVAccount.Expense));
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.initializeHolding.selector,
                POOL_A,
                SC_1,
                asset1,
                mockValuation,
                _expectedLiabilityAccounts(expectedExpenseAccount, navManager.liabilityAccount(CENTRIFUGE_ID_1))
            )
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.InitializeLiability(POOL_A, SC_1, asset1);

        vm.prank(envoy);
        navManager.fromSpoke(POOL_A, _initLiabilityPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    function testFromSpokeErrNotManager() public {
        vm.prank(envoy);
        vm.expectRevert(INAVManager.NotManager.selector);
        navManager.fromSpoke(POOL_A, _initHoldingPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    /// @dev The allowlist is keyed by pool: a manager of POOL_A must not be able to act on POOL_B.
    function testFromSpokeErrCrossPoolManager() public {
        _allowManager(SPOKE_MANAGER, true); // allowed on POOL_A only

        vm.prank(envoy);
        vm.expectRevert(INAVManager.NotManager.selector);
        navManager.fromSpoke(POOL_B, _initHoldingPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    /// @dev The allowlist is also keyed by network: an allowance on one network must not leak to another.
    function testFromSpokeErrCrossNetworkManager() public {
        _allowManager(SPOKE_MANAGER, true); // allowed on CENTRIFUGE_ID_1 only

        vm.prank(envoy);
        vm.expectRevert(INAVManager.NotManager.selector);
        navManager.fromSpoke(POOL_A, _initHoldingPayload(), CENTRIFUGE_ID_2, SPOKE_MANAGER);
    }

    function testFromSpokeErrRevokedManager() public {
        _allowManager(SPOKE_MANAGER, true);
        _allowManager(SPOKE_MANAGER, false);

        vm.prank(envoy);
        vm.expectRevert(INAVManager.NotManager.selector);
        navManager.fromSpoke(POOL_A, _initHoldingPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    function testFromSpokeErrNotEnvoy() public {
        _allowManager(SPOKE_MANAGER, true);

        vm.prank(unauthorized);
        vm.expectRevert(INAVManager.NotEnvoy.selector);
        navManager.fromSpoke(POOL_A, _initHoldingPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    function testFromSpokeUnexpectedValue() public {
        _allowManager(SPOKE_MANAGER, true);

        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(INAVManager.UnexpectedValue.selector);
        navManager.fromSpoke{value: 1}(POOL_A, _initHoldingPayload(), CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }

    function testFromSpokeErrUnsupportedCall() public {
        _allowManager(SPOKE_MANAGER, true);

        // Hook/network configuration is not reachable from the spoke.
        bytes memory payload = abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), address(navHook));
        vm.prank(envoy);
        vm.expectRevert(INAVManager.UnsupportedSpokeCall.selector);
        navManager.fromSpoke(POOL_A, payload, CENTRIFUGE_ID_1, SPOKE_MANAGER);
    }
}

contract NAVManagerLiabilityInitializationTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
    }

    function testInitializeLiabilitySuccess() public {
        AccountId expectedExpenseAccount = withAssetId(asset1, uint16(NAVAccount.Expense));

        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHub.createAccount.selector, POOL_A, expectedExpenseAccount, true)
        );
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(
                IHub.initializeHolding.selector,
                POOL_A,
                SC_1,
                asset1,
                mockValuation,
                _expectedLiabilityAccounts(expectedExpenseAccount, navManager.liabilityAccount(CENTRIFUGE_ID_1))
            )
        );

        vm.expectEmit(true, true, false, true);
        emit INAVManager.InitializeLiability(POOL_A, SC_1, asset1);

        _initializeLiability(POOL_A, SC_1, asset1, mockValuation);

        assertEq(navManager.expenseAccount(asset1).raw(), expectedExpenseAccount.raw());
    }

    function testInitializeLiabilityNotInitialized() public {
        vm.prank(envoy);
        vm.expectRevert(INAVManager.NotInitialized.selector);
        navManager.fromHub(POOL_A, abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), SC_1, asset2));
    }
}

contract NAVManagerOnSyncTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        _setNAVHook(POOL_A, navHook);
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
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
        vm.expectRevert(INAVManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.onSync(POOL_A, SC_1, CENTRIFUGE_ID_1);
    }

    function testOnSyncNoNAVHook() public {
        // Reset NAV hook to zero
        _setNAVHook(POOL_A, INAVHook(address(0)));

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

    function testNetAssetValueWithUnexpectedSigns(
        bool equityIsPositive,
        bool gainIsPositive,
        bool lossIsPositive,
        bool liabilityIsPositive,
        uint128 equityAmount,
        uint128 gainAmount,
        uint128 lossAmount,
        uint128 liabilityAmount
    ) public {
        equityAmount = uint128(bound(equityAmount, 1, type(uint128).max / 4));
        gainAmount = uint128(bound(gainAmount, 1, type(uint128).max / 4));
        lossAmount = uint128(bound(lossAmount, 0, type(uint128).max / 4));
        liabilityAmount = uint128(bound(liabilityAmount, 0, type(uint128).max / 4));

        _mockAccountValue(navManager.equityAccount(CENTRIFUGE_ID_1), equityAmount, equityIsPositive);
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), gainAmount, gainIsPositive);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), lossAmount, lossIsPositive);
        _mockAccountValue(navManager.liabilityAccount(CENTRIFUGE_ID_1), liabilityAmount, liabilityIsPositive);

        uint128 nav = navManager.netAssetValue(POOL_A, CENTRIFUGE_ID_1);

        // If all accounts have expected signs and equity+gain > loss+liability, NAV should be positive
        if (equityIsPositive && gainIsPositive && lossIsPositive && liabilityIsPositive) {
            if (equityAmount + gainAmount > lossAmount + liabilityAmount) {
                assertGt(nav, 0);
            }
        }
    }
}

contract NAVManagerUpdateHoldingTest is NAVManagerTest {
    function testUpdateHoldingValue() public {
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        // updateHoldingValue is permissionless (intended): anyone may trigger a recompute.
        navManager.updateHoldingValue(POOL_A, SC_1, asset1);
    }

    function testUpdateHoldingValuation() public {
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateHoldingValuation.selector, POOL_A, SC_1, asset1, mockValuation)
        );
        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_1, asset1));

        _updateHoldingValuation(POOL_A, SC_1, asset1, mockValuation);
    }
}

contract NAVManagerCloseGainLossTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
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

        _closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossOnlyGain() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 200, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 0, true);

        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: 200, accountId: navManager.gainAccount(CENTRIFUGE_ID_1)});

        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: 200, accountId: navManager.equityAccount(CENTRIFUGE_ID_1)});

        vm.expectCall(address(hub), abi.encodeCall(IHub.updateJournal, (POOL_A, debits, credits)));

        _closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossOnlyLoss() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 0, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 150, true);

        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: 150, accountId: navManager.equityAccount(CENTRIFUGE_ID_1)});

        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: 150, accountId: navManager.lossAccount(CENTRIFUGE_ID_1)});

        vm.expectCall(address(hub), abi.encodeCall(IHub.updateJournal, (POOL_A, debits, credits)));

        _closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossNoGainNoLoss() public {
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 0, true);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 0, true);

        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateJournal.selector), 0);

        _closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }

    function testCloseGainLossNotInitialized() public {
        vm.expectRevert(INAVManager.NotInitialized.selector);
        _closeGainLoss(POOL_A, CENTRIFUGE_ID_2);
    }

    function testCloseGainLossInvalidStateOfAccounts(bool gainIsPositive, bool lossIsPositive) public {
        vm.assume(!gainIsPositive || !lossIsPositive); // At least one account is negative
        _mockAccountValue(navManager.gainAccount(CENTRIFUGE_ID_1), 100, gainIsPositive);
        _mockAccountValue(navManager.lossAccount(CENTRIFUGE_ID_1), 50, lossIsPositive);

        vm.expectRevert(INAVManager.InvalidStateOfAccounts.selector);
        _closeGainLoss(POOL_A, CENTRIFUGE_ID_1);
    }
}

contract NAVManagerHelperFunctionsTest is NAVManagerTest {
    function testEquityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(NAVAccount.Equity));
        AccountId actual = navManager.equityAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testLiabilityAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(NAVAccount.Liability));
        AccountId actual = navManager.liabilityAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testGainAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(NAVAccount.Gain));
        AccountId actual = navManager.gainAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testLossAccount() public view {
        AccountId expected = withCentrifugeId(CENTRIFUGE_ID_1, uint16(NAVAccount.Loss));
        AccountId actual = navManager.lossAccount(CENTRIFUGE_ID_1);
        assertEq(actual.raw(), expected.raw());
    }

    function testAssetAccount() public {
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
        _initializeHolding(POOL_A, SC_1, asset1, mockValuation);

        AccountId expected = withAssetId(asset1, uint16(NAVAccount.Asset));
        AccountId actual = navManager.assetAccount(asset1);
        assertEq(actual.raw(), expected.raw());
    }

    function testExpenseAccount() public {
        _initializeNetwork(POOL_A, CENTRIFUGE_ID_1);
        _initializeLiability(POOL_A, SC_1, asset1, mockValuation);

        AccountId expected = withAssetId(asset1, uint16(NAVAccount.Expense));
        AccountId actual = navManager.expenseAccount(asset1);
        assertEq(actual.raw(), expected.raw());
    }
}

contract NAVManagerOnTransferTest is NAVManagerTest {
    function setUp() public override {
        super.setUp();
        _setNAVHook(POOL_A, navHook);
    }

    function testOnTransferUnauthorized() public {
        vm.expectRevert(INAVManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferNoNAVHook() public {
        _setNAVHook(POOL_A, INAVHook(address(0)));

        vm.expectRevert(INAVManager.InvalidNAVHook.selector);
        vm.prank(holdings);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }

    function testOnTransferSuccess() public {
        vm.expectCall(
            address(navHook),
            abi.encodeWithSelector(INAVHook.onTransfer.selector, POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1)
        );

        vm.expectEmit(true, true, true, true);
        emit INAVManager.Transfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);

        vm.prank(holdings);
        navManager.onTransfer(POOL_A, SC_1, CENTRIFUGE_ID_1, CENTRIFUGE_ID_2, 1);
    }
}

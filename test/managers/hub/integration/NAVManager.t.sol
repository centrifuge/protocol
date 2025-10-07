// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";

import "../../../core/hub/integration/BaseTest.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IValuation} from "../../../../src/core/hub/interfaces/IValuation.sol";
import {ISnapshotHook} from "../../../../src/core/hub/interfaces/ISnapshotHook.sol";

import {INAVHook} from "../../../../src/managers/hub/interfaces/INAVManager.sol";

contract NAVManagerIntegrationTest is BaseTest {
    PoolId constant POOL_A = PoolId.wrap(1);

    ShareClassId scId;

    address manager = makeAddr("manager");

    AssetId asset1 = USDC_C2;
    AssetId asset2 = EUR_STABLE_C2;
    AssetId asset3 = newAssetId(CHAIN_CP, 1);
    AssetId liabilityAsset = newAssetId(CHAIN_CP, 2);
    // differing decimals to test conversion
    uint8 asset1Decimals = 6;
    uint8 asset2Decimals = 12;
    uint8 asset3Decimals = 14;

    function setUp() public override {
        super.setUp();

        cv.registerAsset(asset1, asset1Decimals);
        cv.registerAsset(asset2, asset2Decimals);

        vm.prank(address(root));
        hubRegistry.registerAsset(asset3, asset3Decimals);

        vm.prank(address(root));
        hubRegistry.registerAsset(liabilityAsset, 18);

        _setupMocks();
        _setupPool();

        vm.deal(address(root), 1 ether);
    }

    function _setupMocks() internal {
        vm.mockCall(address(hub), abi.encodeWithSelector(hub.notifySharePrice.selector), abi.encode(uint256(0)));
    }

    function _setupPool() internal {
        vm.prank(address(root));
        hubRegistry.registerPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        scId = hub.addShareClass(POOL_A, "Test Share Class", "TSC", bytes32("1"));

        hub.setSnapshotHook(POOL_A, ISnapshotHook(address(navManager)));
        hub.updateHubManager(POOL_A, address(navManager), true);
        hub.updateHubManager(POOL_A, address(simplePriceManager), true);
        navManager.updateManager(POOL_A, manager, true);

        navManager.setNAVHook(POOL_A, INAVHook(address(simplePriceManager)));

        simplePriceManager.addNotifiedNetwork(POOL_A, CHAIN_CP);
        simplePriceManager.addNotifiedNetwork(POOL_A, CHAIN_CV);

        vm.stopPrank();

        valuation.setPrice(POOL_A, scId, asset1, d18(1, 1));
        valuation.setPrice(POOL_A, scId, asset2, d18(1, 1));
        valuation.setPrice(POOL_A, scId, asset3, d18(1, 1));
        valuation.setPrice(POOL_A, scId, liabilityAsset, d18(1, 1));
    }

    function _testInitializeAndUpdate() internal {
        vm.startPrank(manager);
        navManager.initializeNetwork(POOL_A, CHAIN_CP);
        navManager.initializeNetwork(POOL_A, CHAIN_CV);

        navManager.initializeHolding(POOL_A, scId, asset1, IValuation(address(valuation)));
        navManager.initializeHolding(POOL_A, scId, asset2, IValuation(address(valuation)));
        navManager.initializeHolding(POOL_A, scId, asset3, IValuation(address(valuation)));
        navManager.initializeLiability(POOL_A, scId, liabilityAsset, IValuation(address(valuation)));

        cv.updateHoldingAmount(POOL_A, scId, asset1, uint128(1000 * 10 ** asset1Decimals), d18(1, 1), true, false, 0);
        cv.updateHoldingAmount(POOL_A, scId, asset2, uint128(2300 * 10 ** asset2Decimals), d18(1, 1), true, false, 1);

        vm.expectCall(address(hub), abi.encodeWithSelector(hub.updateSharePrice.selector, POOL_A, scId, d18(1, 1)));
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.notifySharePrice.selector, POOL_A, scId, CHAIN_CP));
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.notifySharePrice.selector, POOL_A, scId, CHAIN_CV));
        cv.updateShares(POOL_A, scId, 3300e18, true, true, 2);

        vm.stopPrank();

        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(
            CHAIN_CP, POOL_A, scId, asset3, uint128(500 * 10 ** asset3Decimals), d18(1, 1), true, false, 0
        );

        vm.expectCall(address(hub), abi.encodeWithSelector(hub.updateSharePrice.selector, POOL_A, scId, d18(1, 1)));
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.notifySharePrice.selector, POOL_A, scId, CHAIN_CP));
        vm.expectCall(address(hub), abi.encodeWithSelector(hub.notifySharePrice.selector, POOL_A, scId, CHAIN_CV));

        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(CHAIN_CP, POOL_A, scId, 500e18, true, true, 1);

        uint128 navHub = navManager.netAssetValue(POOL_A, CHAIN_CP);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, CHAIN_CV);
        (uint128 navHub2, uint128 issuanceHub,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CP);
        (uint128 navSpoke2, uint128 issuanceSpoke,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CV);
        (uint128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);

        assertEq(navHub, 500e18);
        assertEq(navSpoke, 3300e18);
        assertEq(navHub2, navHub);
        assertEq(navSpoke2, navSpoke);
        assertEq(issuanceHub, 500e18);
        assertEq(issuanceSpoke, 3300e18);
        assertEq(globalNAV, 3800e18);
        assertEq(globalIssuance, 3800e18);
    }

    /// forge-config: default.isolate = true
    function testPriceUpdate() public {
        _testInitializeAndUpdate();

        valuation.setPrice(POOL_A, scId, asset1, d18(11, 10)); // 10% increase in value
        valuation.setPrice(POOL_A, scId, asset3, d18(1, 2)); // 50% decrease in value

        vm.prank(manager);
        navManager.updateHoldingValue(POOL_A, scId, asset1);

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(hub.updateSharePrice.selector, POOL_A, scId, d18(3650e18) / d18(3800e18))
        );
        vm.prank(manager);
        navManager.updateHoldingValue(POOL_A, scId, asset3);

        uint128 navHub = navManager.netAssetValue(POOL_A, CHAIN_CP);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, CHAIN_CV);
        (uint128 navHub2, uint128 issuanceHub,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CP);
        (uint128 navSpoke2, uint128 issuanceSpoke,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CV);
        (uint128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);
        (bool spokeGainIsPositive, uint128 spokeGain) =
            accounting.accountValue(POOL_A, navManager.gainAccount(CHAIN_CV));
        (bool hubLossIsPositive, uint128 hubLoss) = accounting.accountValue(POOL_A, navManager.lossAccount(CHAIN_CP));

        assertEq(spokeGain, 100e18);
        assertTrue(spokeGainIsPositive);
        assertEq(hubLoss, 250e18);
        assertTrue(hubLossIsPositive);
        assertEq(navHub, 250e18);

        assertEq(navSpoke, 3400e18);
        assertEq(navHub2, navHub);
        assertEq(navSpoke2, navSpoke);
        assertEq(issuanceHub, 500e18);
        assertEq(issuanceSpoke, 3300e18);
        assertEq(globalNAV, 3650e18); // (3300 * 1.1) + (500 * 0.5) = 3650
        assertEq(globalIssuance, 3800e18);
    }

    /// forge-config: default.isolate = true
    function testTransferShares() public {
        _testInitializeAndUpdate();

        vm.prank(address(root));
        hubHandler.initiateTransferShares{value: 0.1 ether}(
            CHAIN_CP, CHAIN_CV, POOL_A, scId, bytes32("receiver"), 130e18, 0, manager
        );

        uint128 navHub = navManager.netAssetValue(POOL_A, CHAIN_CP);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, CHAIN_CV);
        (uint128 navHub2, uint128 issuanceHub,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CP);
        (uint128 navSpoke2, uint128 issuanceSpoke,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CV);
        (uint128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);

        // NAV and global issuance should remain unchanged, only issuance per network changes
        assertEq(navHub, 500e18);
        assertEq(navSpoke, 3300e18);
        assertEq(navHub2, navHub);
        assertEq(navSpoke2, navSpoke);
        assertEq(issuanceHub, 370e18);
        assertEq(issuanceSpoke, 3430e18);
        assertEq(globalNAV, 3800e18);
        assertEq(globalIssuance, 3800e18);
    }

    /// forge-config: default.isolate = true
    function testLiability() public {
        _testInitializeAndUpdate();

        // Increase liability, e.g. fee payable
        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(hub.updateSharePrice.selector, POOL_A, scId, d18(3750e18) / d18(3800e18))
        );

        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(CHAIN_CP, POOL_A, scId, liabilityAsset, 50e18, d18(1, 1), true, true, 2);

        uint128 navHub = navManager.netAssetValue(POOL_A, CHAIN_CP);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, CHAIN_CV);
        (uint128 navHub2, uint128 issuanceHub,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CP);
        (uint128 navSpoke2, uint128 issuanceSpoke,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CV);
        (uint128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);

        // Liability reduces the NAV
        assertEq(navHub, 450e18);
        assertEq(navSpoke, 3300e18);
        assertEq(navHub2, navHub);
        assertEq(navSpoke2, navSpoke);
        assertEq(issuanceHub, 500e18);
        assertEq(issuanceSpoke, 3300e18);
        assertEq(globalNAV, 3750e18);
        assertEq(globalIssuance, 3800e18);

        // Decrease liability by paying with a cash asset
        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(CHAIN_CP, POOL_A, scId, liabilityAsset, 50e18, d18(1, 1), false, false, 3);
        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(
            CHAIN_CP, POOL_A, scId, asset3, uint128(100 * 10 ** asset3Decimals), d18(1, 2), false, true, 4
        );

        navHub = navManager.netAssetValue(POOL_A, CHAIN_CP);
        navSpoke = navManager.netAssetValue(POOL_A, CHAIN_CV);
        (navHub2, issuanceHub,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CP);
        (navSpoke2, issuanceSpoke,,) = simplePriceManager.networkMetrics(POOL_A, CHAIN_CV);
        (globalNAV, globalIssuance) = simplePriceManager.metrics(POOL_A);

        // NAV should remain unchanged
        assertEq(navHub, 450e18);
        assertEq(navSpoke, 3300e18);
        assertEq(navHub2, navHub);
        assertEq(navSpoke2, navSpoke);
        assertEq(issuanceHub, 500e18);
        assertEq(issuanceSpoke, 3300e18);
        assertEq(globalNAV, 3750e18);
        assertEq(globalIssuance, 3800e18);
    }

    /// forge-config: default.isolate = true
    function testCloseGainLoss() public {
        _testInitializeAndUpdate();

        valuation.setPrice(POOL_A, scId, asset1, d18(11, 10)); // 10% increase in value -> 100e18 gain
        valuation.setPrice(POOL_A, scId, asset3, d18(1, 2)); // 50% decrease in value -> 250e18 loss

        vm.prank(manager);
        navManager.updateHoldingValue(POOL_A, scId, asset1);

        vm.prank(manager);
        navManager.updateHoldingValue(POOL_A, scId, asset3);

        (bool spokeGainIsPositive, uint128 spokeGain) =
            accounting.accountValue(POOL_A, navManager.gainAccount(CHAIN_CV));
        (bool hubLossIsPositive, uint128 hubLoss) = accounting.accountValue(POOL_A, navManager.lossAccount(CHAIN_CP));
        (bool spokeEquityIsPositive, uint128 spokeEquityBefore) =
            accounting.accountValue(POOL_A, navManager.equityAccount(CHAIN_CV));
        (bool hubEquityIsPositive, uint128 hubEquityBefore) =
            accounting.accountValue(POOL_A, navManager.equityAccount(CHAIN_CP));

        assertEq(spokeGain, 100e18);
        assertTrue(spokeGainIsPositive);
        assertEq(hubLoss, 250e18);
        assertTrue(hubLossIsPositive);
        assertEq(spokeEquityBefore, 3300e18);
        assertTrue(spokeEquityIsPositive);
        assertEq(hubEquityBefore, 500e18);
        assertTrue(hubEquityIsPositive);

        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CHAIN_CV);

        (bool spokeGainIsPositiveAfter, uint128 spokeGainAfter) =
            accounting.accountValue(POOL_A, navManager.gainAccount(CHAIN_CV));
        (bool spokeEquityIsPositiveAfter, uint128 spokeEquityAfter) =
            accounting.accountValue(POOL_A, navManager.equityAccount(CHAIN_CV));

        assertEq(spokeGainAfter, 0);
        assertTrue(spokeGainIsPositiveAfter);
        assertEq(spokeEquityAfter, spokeEquityBefore + spokeGain);
        assertTrue(spokeEquityIsPositiveAfter);

        vm.prank(manager);
        navManager.closeGainLoss(POOL_A, CHAIN_CP);

        (bool hubLossIsPositiveAfter, uint128 hubLossAfter) =
            accounting.accountValue(POOL_A, navManager.lossAccount(CHAIN_CP));
        (bool hubEquityIsPositiveAfter, uint128 hubEquityAfter) =
            accounting.accountValue(POOL_A, navManager.equityAccount(CHAIN_CP));

        assertEq(hubLossAfter, 0);
        assertTrue(hubLossIsPositiveAfter);
        assertEq(hubEquityAfter, hubEquityBefore - hubLoss);
        assertTrue(hubEquityIsPositiveAfter);

        uint128 navHub = navManager.netAssetValue(POOL_A, CHAIN_CP);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, CHAIN_CV);

        assertEq(navHub, 250e18);
        assertEq(navSpoke, 3400e18);
    }
}

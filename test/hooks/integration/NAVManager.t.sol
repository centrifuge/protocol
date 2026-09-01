// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";
import {IFeeAccrual} from "../../../src/core/hub/interfaces/IFeeAccrual.sol";
import {IHubRegistry} from "../../../src/core/hub/interfaces/IHubRegistry.sol";
import {ISnapshotHook} from "../../../src/core/hub/interfaces/ISnapshotHook.sol";
import {IShareClassManager} from "../../../src/core/hub/interfaces/IShareClassManager.sol";

import {INAVManager} from "../../../src/hooks/accounting/interfaces/INAVManager.sol";

import {CentrifugeIntegrationTest} from "../../integration/Integration.t.sol";
import {IStdHubPolicy} from "../../../src/policies/hub/interfaces/IStdHubPolicy.sol";
import {StdHubPolicy, StdHubPolicyFactory} from "../../../src/policies/hub/StdHubPolicy.sol";

contract NAVManagerIntegrationTest is CentrifugeIntegrationTest {
    using CastLib for address;

    bytes4 constant UPDATE_SHARE_PRICE = bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128)"));

    // Logical network IDs for NAV segregation — not actual deployed chains
    uint16 constant NETWORK_A = 5;
    uint16 constant NETWORK_B = 6;

    PoolId POOL_A;
    ShareClassId scId;

    address manager = makeAddr("manager");
    address FM = makeAddr("FM");

    AssetId asset1 = newAssetId(NETWORK_B, 1);
    AssetId asset2 = newAssetId(NETWORK_B, 2);
    AssetId asset3 = newAssetId(NETWORK_A, 1);
    AssetId liabilityAsset = newAssetId(NETWORK_A, 2);
    // differing decimals to test conversion
    uint8 asset1Decimals = 6;
    uint8 asset2Decimals = 12;
    uint8 asset3Decimals = 14;

    function setUp() public override {
        super.setUp();

        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);

        vm.startPrank(address(root));
        hubRegistry.registerAsset(asset1, asset1Decimals);
        hubRegistry.registerAsset(asset2, asset2Decimals);
        hubRegistry.registerAsset(asset3, asset3Decimals);
        hubRegistry.registerAsset(liabilityAsset, 18);
        vm.stopPrank();

        _setupMocks();
        _setupPool();

        vm.deal(address(root), 1 ether);
    }

    function _setupMocks() internal {
        vm.mockCall(address(hub), abi.encodeWithSelector(hub.notifySharePrice.selector), abi.encode(uint256(0)));
        vm.mockCall(
            address(messageDispatcher),
            abi.encodeWithSignature(
                "sendExecuteTransferShares(uint16,uint16,uint64,bytes16,bytes32,uint128,uint128,address)"
            ),
            abi.encode(uint256(0))
        );
    }

    function _setupPool() internal {
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        scId = hub.addShareClass(POOL_A, "Test Share Class", "TSC", bytes32(bytes8(POOL_A.raw())));
        hub.setSnapshotHook(POOL_A, ISnapshotHook(address(navManager)));
        hub.updateHubManager(POOL_A, address(navManager), true);
        hub.updateHubManager(POOL_A, address(simplePriceManager), true);
        vm.stopPrank();

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), address(simplePriceManager)));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.SetDefaultValuation), address(valuation)));

        valuation.setPrice(POOL_A, scId, asset1, d18(1, 1));
        valuation.setPrice(POOL_A, scId, asset2, d18(1, 1));
        valuation.setPrice(POOL_A, scId, asset3, d18(1, 1));
        valuation.setPrice(POOL_A, scId, liabilityAsset, d18(1, 1));
    }

    /// @dev Drives a NAVManager privileged action through the policy-supervised path
    ///      (`hub.managerCall` -> `Envoy.callFromHub` -> `navManager.fromHub`), as FM.
    function _navManagerCall(bytes memory payload) internal {
        uint16 localId = messageDispatcher.localCentrifugeId();
        vm.prank(FM);
        hub.managerCall(POOL_A, localId, address(navManager).toBytes32(), payload, 0, 0, address(0));
    }

    function _testInitializeAndUpdate() internal {
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NETWORK_A));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NETWORK_B));

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, asset1));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, asset2));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, asset3));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), scId, liabilityAsset));

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset1, uint128(1000 * 10 ** asset1Decimals), true, false, 0);

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset2, uint128(2300 * 10 ** asset2Decimals), true, false, 1);

        vm.expectCall(address(hub), abi.encodeWithSelector(UPDATE_SHARE_PRICE, POOL_A, scId, d18(1, 1)));
        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(NETWORK_B, POOL_A, scId, 3300e18, true, true, 2);

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_A, POOL_A, scId, asset3, uint128(500 * 10 ** asset3Decimals), true, false, 0);

        vm.expectCall(address(hub), abi.encodeWithSelector(UPDATE_SHARE_PRICE, POOL_A, scId, d18(1, 1)));
        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(NETWORK_A, POOL_A, scId, 500e18, true, true, 1);

        uint128 navHub = navManager.netAssetValue(POOL_A, NETWORK_A);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, NETWORK_B);
        (uint128 navHub2, uint128 issuanceHub,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_A);
        (uint128 navSpoke2, uint128 issuanceSpoke,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
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

        // updateHoldingValue is permissionless (intended): anyone may trigger a recompute.
        navManager.updateHoldingValue(POOL_A, scId, asset1);

        vm.expectCall(
            address(hub), abi.encodeWithSelector(UPDATE_SHARE_PRICE, POOL_A, scId, d18(3650e18) / d18(3800e18))
        );
        navManager.updateHoldingValue(POOL_A, scId, asset3);

        uint128 navHub = navManager.netAssetValue(POOL_A, NETWORK_A);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, NETWORK_B);
        (uint128 navHub2, uint128 issuanceHub,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_A);
        (uint128 navSpoke2, uint128 issuanceSpoke,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        (uint128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);
        (bool spokeGainIsPositive, uint128 spokeGain) =
            accounting.accountValue(POOL_A, navManager.gainAccount(NETWORK_B));
        (bool hubLossIsPositive, uint128 hubLoss) = accounting.accountValue(POOL_A, navManager.lossAccount(NETWORK_A));

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
    function testPriceAgeRefreshesWhenPriceUnchanged() public {
        _testInitializeAndUpdate();

        (D18 priceBefore, uint64 computedAtBefore) = shareClassManager.pricePoolPerShare(POOL_A, scId);

        skip(1 hours);
        navManager.updateHoldingValue(POOL_A, scId, asset1);

        (D18 priceAfter, uint64 computedAtAfter) = shareClassManager.pricePoolPerShare(POOL_A, scId);
        assertEq(priceAfter.raw(), priceBefore.raw());
        assertEq(computedAtAfter, computedAtBefore + 1 hours);
        assertEq(computedAtAfter, block.timestamp);
    }

    /// forge-config: default.isolate = true
    function testFeeAccrualTicksWhenPriceUnchanged() public {
        _testInitializeAndUpdate();

        address feeAccrual = makeAddr("feeAccrual");
        vm.mockCall(feeAccrual, abi.encodeWithSelector(IFeeAccrual.accrue.selector), abi.encode());
        vm.prank(address(root));
        hub.file("feeAccrual", feeAccrual);

        skip(1 hours);
        vm.expectCall(feeAccrual, abi.encodeWithSelector(IFeeAccrual.accrue.selector, POOL_A, scId), 1);
        navManager.updateHoldingValue(POOL_A, scId, asset1);
    }

    /// forge-config: default.isolate = true
    function testTransferShares() public {
        _testInitializeAndUpdate();

        uint128 sharesTransferred = 130e18;

        vm.prank(address(root));
        hubHandler.initiateTransferShares{value: 0.1 ether}(
            NETWORK_A, NETWORK_B, POOL_A, scId, bytes32(0), bytes32("receiver"), sharesTransferred, 0, manager
        );

        (uint128 navHub2, uint128 issuanceHub, uint128 transferredInHub, uint128 transferredOutHub,,) =
            simplePriceManager.networkMetrics(POOL_A, NETWORK_A);
        (uint128 navSpoke2, uint128 issuanceSpoke, uint128 transferredInSpoke, uint128 transferredOutSpoke,,) =
            simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        (uint128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);

        // NAV and issuance should remain unchanged until next onUpdate
        // Transfers are tracked separately and applied during onUpdate
        assertEq(navHub2, 500e18);
        assertEq(navSpoke2, 3300e18);
        assertEq(issuanceHub, 500e18);
        assertEq(issuanceSpoke, 3300e18);
        assertEq(transferredOutHub, sharesTransferred);
        assertEq(transferredInSpoke, sharesTransferred);
        assertEq(globalNAV, 3800e18);
        assertEq(globalIssuance, 3800e18);

        vm.prank(address(navManager));
        simplePriceManager.onUpdate(POOL_A, scId, NETWORK_A, 500e18);

        vm.prank(address(navManager));
        simplePriceManager.onUpdate(POOL_A, scId, NETWORK_B, 3300e18);

        (navHub2, issuanceHub, transferredInHub, transferredOutHub,,) =
            simplePriceManager.networkMetrics(POOL_A, NETWORK_A);
        (navSpoke2, issuanceSpoke, transferredInSpoke, transferredOutSpoke,,) =
            simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        (globalNAV, globalIssuance) = simplePriceManager.metrics(POOL_A);

        assertEq(issuanceHub, 370e18); // 500 - 130
        assertEq(issuanceSpoke, 3430e18); // 3300 + 130
        assertEq(transferredOutHub, 0);
        assertEq(transferredInHub, 0);
        assertEq(transferredInSpoke, 0);
        assertEq(transferredOutSpoke, 0);
        // Global NAV and issuance should be unchanged
        assertEq(globalNAV, 3800e18);
        assertEq(globalIssuance, 3800e18);
    }

    /// forge-config: default.isolate = true
    function testLiability() public {
        _testInitializeAndUpdate();

        // Increase liability, e.g. fee payable
        vm.expectCall(
            address(hub), abi.encodeWithSelector(UPDATE_SHARE_PRICE, POOL_A, scId, d18(3750e18) / d18(3800e18))
        );

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_A, POOL_A, scId, liabilityAsset, 50e18, true, true, 2);

        uint128 navHub = navManager.netAssetValue(POOL_A, NETWORK_A);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, NETWORK_B);
        (uint128 navHub2, uint128 issuanceHub,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_A);
        (uint128 navSpoke2, uint128 issuanceSpoke,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
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

        // Decrease liability by paying with a cash asset. `Holdings.decrease` no longer takes an
        // explicit price: it removes value pro-rata to the amount removed, valued at the holding's
        // current average price (assetAmountValue / assetAmount). The liability is decreased in full
        // (50e18 of 50e18), so its value is fully released regardless of pro-rata math.
        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_A, POOL_A, scId, liabilityAsset, 50e18, false, false, 3);
        // asset3 holds 500 units valued at 500e18 (average price 1:1). Removing 100 of 500 units takes
        // 100/500 = 1/5 of the value, i.e. 100e18, regardless of the asset's current spot price.
        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_A, POOL_A, scId, asset3, uint128(100 * 10 ** asset3Decimals), false, true, 4);

        navHub = navManager.netAssetValue(POOL_A, NETWORK_A);
        navSpoke = navManager.netAssetValue(POOL_A, NETWORK_B);
        (navHub2, issuanceHub,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_A);
        (navSpoke2, issuanceSpoke,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        (globalNAV, globalIssuance) = simplePriceManager.metrics(POOL_A);

        // Liability fully released (+50e18) but asset3 lost 100e18 of pro-rata value: net -50e18 vs.
        // the pre-decrease 450e18, landing at 400e18 (500e18 asset3 remaining - 0 liability).
        assertEq(navHub, 400e18);
        assertEq(navSpoke, 3300e18);
        assertEq(navHub2, navHub);
        assertEq(navSpoke2, navSpoke);
        assertEq(issuanceHub, 500e18);
        assertEq(issuanceSpoke, 3300e18);
        assertEq(globalNAV, 3700e18);
        assertEq(globalIssuance, 3800e18);
    }

    /// forge-config: default.isolate = true
    function testCloseGainLoss() public {
        _testInitializeAndUpdate();

        valuation.setPrice(POOL_A, scId, asset1, d18(11, 10)); // 10% increase in value -> 100e18 gain
        valuation.setPrice(POOL_A, scId, asset3, d18(1, 2)); // 50% decrease in value -> 250e18 loss

        navManager.updateHoldingValue(POOL_A, scId, asset1);

        navManager.updateHoldingValue(POOL_A, scId, asset3);

        (bool spokeGainIsPositive, uint128 spokeGain) =
            accounting.accountValue(POOL_A, navManager.gainAccount(NETWORK_B));
        (bool hubLossIsPositive, uint128 hubLoss) = accounting.accountValue(POOL_A, navManager.lossAccount(NETWORK_A));
        (bool spokeEquityIsPositive, uint128 spokeEquityBefore) =
            accounting.accountValue(POOL_A, navManager.equityAccount(NETWORK_B));
        (bool hubEquityIsPositive, uint128 hubEquityBefore) =
            accounting.accountValue(POOL_A, navManager.equityAccount(NETWORK_A));

        assertEq(spokeGain, 100e18);
        assertTrue(spokeGainIsPositive);
        assertEq(hubLoss, 250e18);
        assertTrue(hubLossIsPositive);
        assertEq(spokeEquityBefore, 3300e18);
        assertTrue(spokeEquityIsPositive);
        assertEq(hubEquityBefore, 500e18);
        assertTrue(hubEquityIsPositive);

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.CloseGainLoss), NETWORK_B));

        (bool spokeGainIsPositiveAfter, uint128 spokeGainAfter) =
            accounting.accountValue(POOL_A, navManager.gainAccount(NETWORK_B));
        (bool spokeEquityIsPositiveAfter, uint128 spokeEquityAfter) =
            accounting.accountValue(POOL_A, navManager.equityAccount(NETWORK_B));

        assertEq(spokeGainAfter, 0);
        assertTrue(spokeGainIsPositiveAfter);
        assertEq(spokeEquityAfter, spokeEquityBefore + spokeGain);
        assertTrue(spokeEquityIsPositiveAfter);

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.CloseGainLoss), NETWORK_A));

        (bool hubLossIsPositiveAfter, uint128 hubLossAfter) =
            accounting.accountValue(POOL_A, navManager.lossAccount(NETWORK_A));
        (bool hubEquityIsPositiveAfter, uint128 hubEquityAfter) =
            accounting.accountValue(POOL_A, navManager.equityAccount(NETWORK_A));

        assertEq(hubLossAfter, 0);
        assertTrue(hubLossIsPositiveAfter);
        assertEq(hubEquityAfter, hubEquityBefore - hubLoss);
        assertTrue(hubEquityIsPositiveAfter);

        uint128 navHub = navManager.netAssetValue(POOL_A, NETWORK_A);
        uint128 navSpoke = navManager.netAssetValue(POOL_A, NETWORK_B);

        assertEq(navHub, 250e18);
        assertEq(navSpoke, 3400e18);
    }

    /// forge-config: default.isolate = true
    function testEdgeCaseTransferWithZeroIssuanceCausesRevert() public {
        // When ShareClassManager.issuance is 0 on the source network and a transfer happens,
        // calling SimplePriceManager.onUpdate causes ShareClassManager.issuance() to revert with NegativeIssuance.
        // This blocks NAV updates for the pool until submitQueuedShares with snapshot = true is called from the Spoke on the source network.

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NETWORK_A));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NETWORK_B));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, asset3));

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_A, POOL_A, scId, asset3, uint128(500 * 10 ** asset3Decimals), true, false, 0);

        // Issue shares only to destination network to have some global issuance
        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(NETWORK_B, POOL_A, scId, 200e18, true, true, 0);

        vm.prank(address(root));
        hubHandler.initiateTransferShares{value: 0.1 ether}(
            NETWORK_A, NETWORK_B, POOL_A, scId, bytes32(0), bytes32("receiver"), 100e18, 0, manager
        );

        // issuance is -100 on source network after transfer
        // calling ShareClassManager.issuance in onUpdate will revert

        vm.expectRevert(abi.encodeWithSelector(IShareClassManager.NegativeIssuance.selector));
        vm.prank(address(navManager));
        simplePriceManager.onUpdate(POOL_A, scId, NETWORK_A, 500e18);
    }
}

/// @dev End-to-end deficit gate: an over-decrease (e.g. revoke-without-assets) pushes the share class-network into
///      deficit; `onSync` holds the last published price instead of reverting, and resumes once a refill clears it.
contract NAVManagerDeficitGateTest is NAVManagerIntegrationTest {
    /// forge-config: default.isolate = true
    function testDeficitFreezesAndResumesPrice() public {
        _testInitializeAndUpdate();

        // Baseline: NETWORK_B at 3300e18, no deficit.
        (uint128 navBefore, uint128 issuanceBefore,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        assertEq(navBefore, 3300e18);
        assertEq(holdings.deficitCount(POOL_A, scId, NETWORK_B), 0);

        // Over-decrease asset1 by 1500: holding saturates at zero, network enters deficit; onSync must
        // skip, not revert.
        vm.expectEmit(true, true, true, true);
        emit INAVManager.SkipSync(POOL_A, scId, NETWORK_B, 1, 1);

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset1, uint128(1500 * 10 ** asset1Decimals), false, true, 3);

        // Gate engaged: live NAV reflects the shortfall, but the published price is held.
        assertEq(holdings.deficitCount(POOL_A, scId, NETWORK_B), 1);
        assertEq(navManager.netAssetValue(POOL_A, NETWORK_B), 2300e18); // live: equity down 1000e18
        (uint128 navDuring, uint128 issuanceDuring,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        assertEq(navDuring, navBefore); // frozen at last good
        assertEq(issuanceDuring, issuanceBefore);

        // Refill asset1 by 1500: holding positive again, deficit clears, trailing snapshot resumes pricing.
        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset1, uint128(1500 * 10 ** asset1Decimals), true, true, 4);

        assertEq(holdings.deficitCount(POOL_A, scId, NETWORK_B), 0);
        (uint128 navAfter, uint128 issuanceAfter,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        assertEq(navAfter, 3300e18); // 1000 - 1500 + 1500 = 1000 asset1 restored -> NAV back to 3300e18
        assertEq(issuanceAfter, issuanceBefore);
    }
}

/// @dev End-to-end share-price rate guard under on-chain accounting: the recompute path is permissionless
///      (anyone -> NAVManager.updateHoldingValue -> ... -> Hub.updateSharePrice), so re-commits of an
///      unchanged price must leave the policy's baseline where the last actual move put it.
contract NAVManagerPriceGuardTest is NAVManagerIntegrationTest {
    uint128 constant RATE = 1e12; // per second
    uint128 constant CAP = 5e17;

    address attacker = makeAddr("attacker");

    StdHubPolicy policy;

    function _installPolicy() internal {
        StdHubPolicyFactory policyFactory = new StdHubPolicyFactory(hub, multiAdapter, shareClassManager);
        policy = StdHubPolicy(
            address(
                policyFactory.newHubPolicy(
                    IStdHubPolicy.Config({
                        delay: 1 days,
                        expiry: 7 days,
                        escalation: 7 days,
                        maxAbsolutePriceDelta: CAP,
                        thresholdPerSecond: RATE,
                        maxBrmPriceDeviation: type(uint128).max,
                        onchainAccounting: true,
                        navManager: address(navManager),
                        simplePriceManager: address(simplePriceManager),
                        requestManager: address(batchRequestManager),
                        bridgingHook: address(0),
                        oracleValuation: address(0),
                        allowlist: new IStdHubPolicy.Entry[](0)
                    })
                )
            )
        );

        vm.prank(address(root));
        hub.setPolicy(POOL_A, policy);
    }

    /// forge-config: default.isolate = true
    function testNoOpRecomputesKeepTheGuardWindow() public {
        _testInitializeAndUpdate();
        _installPolicy();

        // First move under the policy anchors the baseline: asset2 +1% -> NAV 3823e18.
        valuation.setPrice(POOL_A, scId, asset2, d18(101, 100));
        navManager.updateHoldingValue(POOL_A, scId, asset2);
        uint64 baseline = policy.lastPriceUpdate(POOL_A, scId);
        assertEq(baseline, block.timestamp);

        skip(1 hours);

        // Anyone can drive a recompute; with no valuation change the price is re-committed unchanged.
        for (uint256 i; i < 5; i++) {
            vm.prank(attacker);
            navManager.updateHoldingValue(POOL_A, scId, asset1);
        }

        (D18 price, uint64 computedAt) = shareClassManager.pricePoolPerShare(POOL_A, scId);
        assertEq(price.raw(), (d18(3823e18) / d18(3800e18)).raw());
        assertEq(computedAt, block.timestamp); // the age tracks the recompute
        assertEq(policy.lastPriceUpdate(POOL_A, scId), baseline); // the guard window does not

        // asset3 -10e18 -> 2.63e15 over the full hour, under RATE: still runs synchronously.
        valuation.setPrice(POOL_A, scId, asset3, d18(98, 100));
        navManager.updateHoldingValue(POOL_A, scId, asset3);

        (price,) = shareClassManager.pricePoolPerShare(POOL_A, scId);
        assertEq(price.raw(), (d18(3813e18) / d18(3800e18)).raw());
        assertEq(policy.lastPriceUpdate(POOL_A, scId), block.timestamp);

        // Guard is armed: the same-sized move again in this block has no elapsed time to bound it.
        valuation.setPrice(POOL_A, scId, asset3, d18(96, 100));
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        navManager.updateHoldingValue(POOL_A, scId, asset3);
    }
}

/// @dev A pool's assets are shared across its share classes, so two share classes over one asset are two
///      holdings sharing one asset account. Before the reuse in `_createHolding` the second one reverted
///      `AccountExists`, which is what blocked a tranched pool from setting up.
contract NAVManagerSharedAssetTest is NAVManagerIntegrationTest {
    function testTwoShareClassesShareOneAssetAccount() public {
        vm.prank(FM);
        ShareClassId scId2 =
            hub.addShareClass(POOL_A, "Junior Share Class", "JSC", bytes32(bytes8(POOL_A.raw())) | bytes32(uint256(2)));
        valuation.setPrice(POOL_A, scId2, asset1, d18(1, 1));

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NETWORK_B));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, asset1));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId2, asset1));

        assertTrue(holdings.isInitialized(POOL_A, scId, asset1));
        assertTrue(holdings.isInitialized(POOL_A, scId2, asset1));
        assertEq(
            holdings.accountId(POOL_A, scId2, asset1, 0).raw(),
            holdings.accountId(POOL_A, scId, asset1, 0).raw(),
            "both holdings must debit the one shared asset account"
        );

        // Each class reports its own inflow, both journal into the shared account, so the pool-wide NAV
        // counts both. Snapshots stay open so the (single-class) price hook is not driven here.
        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset1, uint128(1000 * 10 ** asset1Decimals), true, false, 0);

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId2, asset1, uint128(500 * 10 ** asset1Decimals), true, false, 0);

        // Assert the debit side too, not just the resulting NAV: the point of the reuse is that both inflows
        // land in one account, and a NAV that happened to be right over two separate accounts would not show it.
        (bool isPositive, uint128 assetValue) = accounting.accountValue(POOL_A, navManager.assetAccount(asset1));
        assertTrue(isPositive);
        assertEq(assetValue, 1500e18, "both inflows must sum in the one shared asset account");

        assertEq(navManager.netAssetValue(POOL_A, NETWORK_B), 1500e18, "junior inflow must count towards pool NAV");
    }

    /// @dev The deficit gate covers the whole pool-network, so a junior over-decrease holds the senior sync
    ///      too: the NAV a senior sync would publish reads the same shared accounts the junior contaminated.
    function testDeficitUnderOneShareClassHoldsTheOther() public {
        vm.prank(FM);
        ShareClassId scId2 =
            hub.addShareClass(POOL_A, "Junior Share Class", "JSC", bytes32(bytes8(POOL_A.raw())) | bytes32(uint256(2)));
        valuation.setPrice(POOL_A, scId2, asset1, d18(1, 1));

        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NETWORK_B));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId, asset1));
        _navManagerCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scId2, asset1));

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset1, uint128(1000 * 10 ** asset1Decimals), true, false, 0);

        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId2, asset1, uint128(500 * 10 ** asset1Decimals), true, false, 0);

        // A clean senior snapshot publishes the pool-wide NAV, which is the value the gate has to hold.
        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(NETWORK_B, POOL_A, scId, 1500e18, true, true, 1);

        (uint128 navBefore,,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        assertEq(navBefore, 1500e18, "the clean senior sync publishes both classes' inflows");

        // Junior over-decreases: 800 out against 500 held, so 300 is carried and its amount saturates at zero.
        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId2, asset1, uint128(800 * 10 ** asset1Decimals), false, false, 1);

        assertEq(holdings.deficitCount(POOL_A, scId2, NETWORK_B), 1, "the deficit is reported under the junior");
        assertEq(holdings.deficitCount(POOL_A, scId, NETWORK_B), 0, "the senior's own count stays clean");
        assertEq(holdings.networkDeficitCount(POOL_A, NETWORK_B), 1, "the rollup carries it for the whole network");

        // The junior's 500 was journalled out of the shared account, so the live NAV is now misstated: the
        // senior's next snapshot would publish that, which is what the rollup gate holds back.
        assertEq(navManager.netAssetValue(POOL_A, NETWORK_B), 1000e18, "live NAV carries the junior's shortfall");

        vm.expectEmit();
        emit INAVManager.SkipSync(POOL_A, scId, NETWORK_B, 0, 1);
        vm.prank(address(messageDispatcher));
        hubHandler.updateAssets(NETWORK_B, POOL_A, scId, asset1, uint128(1 * 10 ** asset1Decimals), true, true, 2);

        (uint128 navAfter,,,,,) = simplePriceManager.networkMetrics(POOL_A, NETWORK_B);
        assertEq(navAfter, navBefore, "the senior sync is held, so the published NAV stays pre-deficit");
    }
}

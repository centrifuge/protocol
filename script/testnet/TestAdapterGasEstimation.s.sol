// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTestData} from "./BaseTestData.s.sol";

import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AccountId} from "../../src/core/types/AccountId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title TestAdapterGasEstimation
 * @notice Optimized script for testing cross-chain adapter gas estimations
 * @dev This script separates pool setup from adapter setup, allowing repeated
 *      NotifyShareClass tests without re-running expensive adapter configuration.
 *
 *      THREE-PHASE WORKFLOW:
 *
 *      Phase 1: runPoolSetup() - ONE TIME
 *      - Creates pools on hub (no cross-chain messages)
 *      - Registers asset, creates accounts, initializes holdings
 *      - Cost: Hub gas only (~0.1 ETH per pool subsidy)
 *
 *      Phase 2: runAdapterSetup() - ONE TIME PER ADAPTER
 *      - Configures isolated adapter for each pool
 *      - Sends SetPoolAdapters + NotifyPool cross-chain
 *      - Cost: XC fees (~0.1-0.2 ETH per adapter)
 *
 *      Phase 3: runShareClassTest() - REPEATABLE
 *      - Adds new share class to existing pool
 *      - Sends NotifyShareClass through isolated adapter
 *      - Cost: 1 XC message (~0.1 ETH)
 *
 *      COMPARISON WITH TestAdapterIsolation.s.sol:
 *      - Old: 6 pools × (setup + adapter config) = 6 adapter setups
 *      - New: 4 pools × 1 adapter setup + N share class tests
 *
 * Usage:
 *   # Phase 1: Create pools (hub only)
 *   NETWORK=base-sepolia forge script script/testnet/TestAdapterGasEstimation.s.sol:TestAdapterGasEstimation \
 *     --sig "runPoolSetup()" --rpc-url $BASE_SEPOLIA_RPC --broadcast -vvvv
 *
 *   # Phase 2: Configure adapters (after Phase 1)
 *   NETWORK=base-sepolia forge script script/testnet/TestAdapterGasEstimation.s.sol:TestAdapterGasEstimation \
 *     --sig "runAdapterSetup()" --rpc-url $BASE_SEPOLIA_RPC --broadcast -vvvv
 *
 *   # Wait for XC relay of SetPoolAdapters + NotifyPool
 *
 *   # Phase 3: Test share class (repeatable)
 *   NETWORK=base-sepolia forge script script/testnet/TestAdapterGasEstimation.s.sol:TestAdapterGasEstimation \
 *     --sig "runShareClassTest()" --rpc-url $BASE_SEPOLIA_RPC --broadcast -vvvv
 */
contract TestAdapterGasEstimation is BaseTestData {
    using CastLib for address;

    //----------------------------------------------------------------------------------------------
    // CONSTANTS
    //----------------------------------------------------------------------------------------------

    uint256 constant POOL_SUBSIDY = 0.1 ether;
    uint48 constant DEFAULT_GAS_TEST_BASE = 91000; // Different from TestAdapterIsolation (90000)

    address constant ARBITRUM_SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    uint8 constant ADAPTER_COUNT = 4; // 0=Axelar, 1=LayerZero, 2=Wormhole, 3=Chainlink

    //----------------------------------------------------------------------------------------------
    // TYPES
    //----------------------------------------------------------------------------------------------

    enum AdapterType {
        Axelar,
        LayerZero,
        Wormhole,
        Chainlink
    }

    //----------------------------------------------------------------------------------------------
    // STORAGE
    //----------------------------------------------------------------------------------------------

    address public admin;
    uint16 public hubCentrifugeId;
    uint16 public spokeCentrifugeId;
    string public spokeNetworkName;
    uint48 public gasTestBase;

    uint8 internal selectedAdapter = 255; // 255 = all adapters

    //----------------------------------------------------------------------------------------------
    // ENTRY POINTS
    //----------------------------------------------------------------------------------------------

    function run() public override {
        runPoolSetup();
    }

    /// @notice Phase 1: Create pools on hub (no cross-chain messages)
    /// @dev Run this ONCE to set up pools. Cost: hub gas only.
    function runPoolSetup() public {
        _loadConfig();
        _loadAdapterSelection();
        _logConfig();

        console.log("\n=== PHASE 1: Pool Setup (Hub Only) ===\n");

        vm.startBroadcast();
        _phase1_CreatePools();
        vm.stopBroadcast();

        _logPoolSetupComplete();
    }

    /// @notice Phase 2: Configure adapters and notify pools
    /// @dev Run this ONCE after runPoolSetup(). Sends SetPoolAdapters + NotifyPool XC messages.
    function runAdapterSetup() public {
        _loadConfig();
        _loadAdapterSelection();
        _logConfig();

        console.log("\n=== PHASE 2: Adapter Setup (XC Messages) ===\n");

        vm.startBroadcast();
        _phase2_ConfigureAdapters();
        vm.stopBroadcast();

        _logAdapterSetupComplete();
    }

    /// @notice Phase 3: Add share class and send NotifyShareClass
    /// @dev Run this REPEATEDLY to test NotifyShareClass gas estimation.
    function runShareClassTest() public {
        _loadConfig();
        _loadAdapterSelection();
        _logConfig();

        console.log("\n=== PHASE 3: Share Class Test (Repeatable) ===\n");

        vm.startBroadcast();
        _phase3_TestShareClass();
        vm.stopBroadcast();

        _logShareClassTestComplete();
    }

    //----------------------------------------------------------------------------------------------
    // SINGLE ADAPTER ENTRY POINTS
    //----------------------------------------------------------------------------------------------

    function runAxelar_PoolSetup() public {
        selectedAdapter = uint8(AdapterType.Axelar);
        runPoolSetup();
    }

    function runAxelar_AdapterSetup() public {
        selectedAdapter = uint8(AdapterType.Axelar);
        runAdapterSetup();
    }

    function runAxelar_ShareClassTest() public {
        selectedAdapter = uint8(AdapterType.Axelar);
        runShareClassTest();
    }

    function runLayerZero_PoolSetup() public {
        selectedAdapter = uint8(AdapterType.LayerZero);
        runPoolSetup();
    }

    function runLayerZero_AdapterSetup() public {
        selectedAdapter = uint8(AdapterType.LayerZero);
        runAdapterSetup();
    }

    function runLayerZero_ShareClassTest() public {
        selectedAdapter = uint8(AdapterType.LayerZero);
        runShareClassTest();
    }

    function runWormhole_PoolSetup() public {
        selectedAdapter = uint8(AdapterType.Wormhole);
        runPoolSetup();
    }

    function runWormhole_AdapterSetup() public {
        selectedAdapter = uint8(AdapterType.Wormhole);
        runAdapterSetup();
    }

    function runWormhole_ShareClassTest() public {
        selectedAdapter = uint8(AdapterType.Wormhole);
        runShareClassTest();
    }

    function runChainlink_PoolSetup() public {
        selectedAdapter = uint8(AdapterType.Chainlink);
        runPoolSetup();
    }

    function runChainlink_AdapterSetup() public {
        selectedAdapter = uint8(AdapterType.Chainlink);
        runAdapterSetup();
    }

    function runChainlink_ShareClassTest() public {
        selectedAdapter = uint8(AdapterType.Chainlink);
        runShareClassTest();
    }

    //----------------------------------------------------------------------------------------------
    // CONFIGURATION
    //----------------------------------------------------------------------------------------------

    function _loadConfig() internal {
        string memory network = vm.envString("NETWORK");
        string memory config = vm.readFile(string.concat("env/", network, ".json"));

        hubCentrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        xcGasPerCall = vm.envOr("XC_GAS_PER_CALL", DEFAULT_XC_GAS_PER_CALL);

        spokeNetworkName = vm.envOr("SPOKE_NETWORK", string("arbitrum-sepolia"));
        string memory spokeConfig = vm.readFile(string.concat("env/", spokeNetworkName, ".json"));
        spokeCentrifugeId = uint16(vm.parseJsonUint(spokeConfig, "$.network.centrifugeId"));

        try vm.envAddress("PROTOCOL_ADMIN") returns (address a) {
            admin = a;
        } catch {
            admin = msg.sender;
        }

        gasTestBase = uint48(vm.envOr("GAS_TEST_BASE", uint256(DEFAULT_GAS_TEST_BASE)));

        loadContractsFromConfig(config);
    }

    function _logConfig() internal view {
        console.log("=== Gas Estimation Test Configuration ===");
        console.log("Hub CentrifugeId:", hubCentrifugeId);
        console.log("Spoke CentrifugeId:", spokeCentrifugeId);
        console.log("Spoke Network:", spokeNetworkName);
        console.log("Admin:", admin);
        console.log("XC Gas Per Call:", xcGasPerCall);
        console.log("Gas Test Base:", gasTestBase);
        console.log("==========================================\n");
    }

    function _loadAdapterSelection() internal {
        if (selectedAdapter != 255) {
            console.log("*** SINGLE ADAPTER MODE:", _adapterName(AdapterType(selectedAdapter)), "***\n");
            return;
        }

        string memory adapterEnv = vm.envOr("ADAPTER", string("all"));
        bytes32 adapterHash = keccak256(bytes(adapterEnv));

        if (adapterHash == keccak256("axelar") || adapterHash == keccak256("0")) {
            selectedAdapter = uint8(AdapterType.Axelar);
        } else if (adapterHash == keccak256("layerzero") || adapterHash == keccak256("1")) {
            selectedAdapter = uint8(AdapterType.LayerZero);
        } else if (adapterHash == keccak256("wormhole") || adapterHash == keccak256("2")) {
            selectedAdapter = uint8(AdapterType.Wormhole);
        } else if (adapterHash == keccak256("chainlink") || adapterHash == keccak256("3")) {
            selectedAdapter = uint8(AdapterType.Chainlink);
        } else {
            selectedAdapter = 255;
        }

        if (selectedAdapter != 255) {
            console.log("*** SINGLE ADAPTER MODE:", _adapterName(AdapterType(selectedAdapter)), "***\n");
        }
    }

    function _shouldTestAdapter(uint8 adapterIdx) internal view returns (bool) {
        return selectedAdapter == 255 || selectedAdapter == adapterIdx;
    }

    //----------------------------------------------------------------------------------------------
    // PHASE 1: CREATE POOLS (HUB ONLY)
    //----------------------------------------------------------------------------------------------

    function _phase1_CreatePools() internal {
        AssetId assetId = newAssetId(spokeCentrifugeId, 1);
        _ensureAssetRegistered(spokeCentrifugeId, assetId);

        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            if (!_shouldTestAdapter(adapterIdx)) continue;
            _createPoolOnHub(AdapterType(adapterIdx), assetId);
        }
    }

    function _createPoolOnHub(AdapterType adapter, AssetId assetId) internal {
        uint48 poolIndex = _poolIndex(uint8(adapter));
        PoolId poolId = hubRegistry.poolId(hubCentrifugeId, poolIndex);

        if (hubRegistry.exists(poolId)) {
            console.log("Pool already exists, skipping:", _adapterName(adapter));
            return;
        }

        console.log("\n--- Creating pool for:", _adapterName(adapter));
        console.log("    Pool Index:", poolIndex);

        // Deposit subsidy
        subsidyManager.deposit{value: POOL_SUBSIDY}(poolId);

        // Create pool
        opsGuardian.createPool(poolId, msg.sender, USD_ID);

        // Create accounts
        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), true);

        // Add first share class
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);
        string memory shareName = string.concat("GasTest-", _adapterName(adapter), "-SC0");
        string memory shareSymbol = string.concat("GT", _adapterSymbol(adapter), "0");
        bytes32 shareClassMeta = bytes32(abi.encodePacked(bytes8(poolId.raw()), bytes24(keccak256(bytes(shareName)))));
        hub.addShareClass(poolId, shareName, shareSymbol, shareClassMeta);

        // Initialize holding and price
        if (hubRegistry.isRegistered(assetId)) {
            hub.initializeHolding(
                poolId,
                scId,
                assetId,
                identityValuation,
                AccountId.wrap(0x01),
                AccountId.wrap(0x02),
                AccountId.wrap(0x03),
                AccountId.wrap(0x04)
            );
        }
        hub.updateSharePrice(poolId, scId, d18(1, 1), uint64(block.timestamp));

        // Set pool metadata
        string memory poolMeta = string.concat("GasTest-", _adapterName(adapter));
        hub.setPoolMetadata(poolId, bytes(poolMeta));

        console.log("    PoolId:", vm.toString(abi.encode(poolId)));
        console.log("    ShareClassId:", vm.toString(abi.encode(scId)));
        console.log("    [Hub only - no XC messages sent]");
    }

    //----------------------------------------------------------------------------------------------
    // PHASE 2: CONFIGURE ADAPTERS
    //----------------------------------------------------------------------------------------------

    function _phase2_ConfigureAdapters() internal {
        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            if (!_shouldTestAdapter(adapterIdx)) continue;
            _configureAdapterAndNotifyPool(AdapterType(adapterIdx));
        }
    }

    function _configureAdapterAndNotifyPool(AdapterType adapter) internal {
        uint48 poolIndex = _poolIndex(uint8(adapter));
        PoolId poolId = hubRegistry.poolId(hubCentrifugeId, poolIndex);

        if (!hubRegistry.exists(poolId)) {
            console.log("Pool does not exist, run runPoolSetup() first:", _adapterName(adapter));
            return;
        }

        console.log("\n--- Configuring adapter for:", _adapterName(adapter));

        // Configure isolated adapter
        IAdapter adapterInstance = _getAdapter(adapter);

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = adapterInstance;

        bytes32[] memory remoteAdapters = new bytes32[](1);
        remoteAdapters[0] = address(adapterInstance).toBytes32();

        hub.setAdapters{value: xcGasPerCall}(poolId, spokeCentrifugeId, localAdapters, remoteAdapters, 1, 0, msg.sender);
        console.log("    SetPoolAdapters sent via", _adapterName(adapter));

        // Send NotifyPool to create pool on spoke
        hub.notifyPool{value: xcGasPerCall}(poolId, spokeCentrifugeId, msg.sender);
        console.log("    NotifyPool sent via", _adapterName(adapter));

        console.log("    Total XC messages: 2");
    }

    //----------------------------------------------------------------------------------------------
    // PHASE 3: SHARE CLASS TEST
    //----------------------------------------------------------------------------------------------

    function _phase3_TestShareClass() internal {
        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            if (!_shouldTestAdapter(adapterIdx)) continue;
            _addShareClassAndNotify(AdapterType(adapterIdx));
        }
    }

    function _addShareClassAndNotify(AdapterType adapter) internal {
        uint48 poolIndex = _poolIndex(uint8(adapter));
        PoolId poolId = hubRegistry.poolId(hubCentrifugeId, poolIndex);

        if (!hubRegistry.exists(poolId)) {
            console.log("Pool does not exist, run runPoolSetup() first:", _adapterName(adapter));
            return;
        }

        console.log("\n--- Adding share class for:", _adapterName(adapter));

        // Get next share class index
        ShareClassId scId = shareClassManager.previewNextShareClassId(poolId);
        uint32 scIndex = scId.index();

        console.log("    Share class index:", scIndex);

        // Add new share class on hub
        string memory shareName = string.concat("GasTest-", _adapterName(adapter), "-SC", vm.toString(scIndex));
        string memory shareSymbol = string.concat("GT", _adapterSymbol(adapter), vm.toString(scIndex));
        bytes32 shareClassMeta = bytes32(abi.encodePacked(bytes8(poolId.raw()), bytes24(keccak256(bytes(shareName)))));
        hub.addShareClass(poolId, shareName, shareSymbol, shareClassMeta);

        console.log("    Added share class on hub:", shareName);

        // Send NotifyShareClass through isolated adapter
        hub.notifyShareClass{value: xcGasPerCall}(
            poolId, scId, spokeCentrifugeId, address(redemptionRestrictionsHook).toBytes32(), msg.sender
        );

        console.log("    NotifyShareClass sent via", _adapterName(adapter));
        console.log("    ShareClassId:", vm.toString(abi.encode(scId)));
    }

    //----------------------------------------------------------------------------------------------
    // ASSET REGISTRATION
    //----------------------------------------------------------------------------------------------

    function _ensureAssetRegistered(uint16 targetCentrifugeId, AssetId assetId) internal {
        if (hubRegistry.isRegistered(assetId)) {
            console.log("[Asset] Already registered on Hub, assetId:", assetId.raw());
            return;
        }

        bool isCrossChain = targetCentrifugeId != hubCentrifugeId;
        if (isCrossChain) {
            // For cross-chain, asset registration happens from spoke. Continue without it.
            // Pools can still be created - holdings init will be skipped if asset not registered.
            console.log("[Asset] Not registered on hub. Holdings init will be skipped.");
            console.log(
                string.concat(
                    "        To register: NETWORK=", spokeNetworkName, " forge script ... --sig 'registerAssetOnly()'"
                )
            );
            return;
        }

        address usdcAddress = _resolveUsdcAddress(targetCentrifugeId);
        spoke.registerAsset{value: xcGasPerCall}(targetCentrifugeId, usdcAddress, 0, msg.sender);
        console.log("[Asset] Registered asset locally:", usdcAddress);
    }

    function _resolveUsdcAddress(uint16 centrifugeId) internal view returns (address) {
        try vm.envAddress("TEST_USDC_ADDRESS") returns (address addr) {
            return addr;
        } catch {}

        if (centrifugeId == 2) return BASE_SEPOLIA_USDC;
        if (centrifugeId == 3) return ARBITRUM_SEPOLIA_USDC;

        console.log("[Asset] No hardcoded USDC for centrifugeId:", centrifugeId);
        revert("Set TEST_USDC_ADDRESS env var for this chain.");
    }

    /// @notice Register asset from spoke chain (for cross-chain setups)
    function registerAssetOnly() public {
        string memory network = vm.envString("NETWORK");
        string memory config = vm.readFile(string.concat("env/", network, ".json"));
        uint16 localCentrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        loadContractsFromConfig(config);
        xcGasPerCall = vm.envOr("XC_GAS_PER_CALL", DEFAULT_XC_GAS_PER_CALL);

        string memory hubNetwork = vm.envOr("HUB_NETWORK", string("base-sepolia"));
        string memory hubConfig = vm.readFile(string.concat("env/", hubNetwork, ".json"));
        uint16 targetHubCentrifugeId = uint16(vm.parseJsonUint(hubConfig, "$.network.centrifugeId"));

        console.log("=== Asset Registration (run on SPOKE chain) ===");
        console.log("Local CentrifugeId:", localCentrifugeId);
        console.log("Target Hub CentrifugeId:", targetHubCentrifugeId);

        address localUsdc = _resolveUsdcAddress(localCentrifugeId);
        console.log("Local USDC address:", localUsdc);

        vm.startBroadcast();
        spoke.registerAsset{value: xcGasPerCall}(targetHubCentrifugeId, localUsdc, 0, msg.sender);
        vm.stopBroadcast();

        console.log("\n[Asset] Registration XC message sent to hub!");
    }

    //----------------------------------------------------------------------------------------------
    // UTILITIES
    //----------------------------------------------------------------------------------------------

    function _getAdapter(AdapterType adapter) internal view returns (IAdapter) {
        if (adapter == AdapterType.Axelar) return axelarAdapter;
        if (adapter == AdapterType.LayerZero) return layerZeroAdapter;
        if (adapter == AdapterType.Wormhole) return wormholeAdapter;
        return chainlinkAdapter;
    }

    function _poolIndex(uint8 adapterIdx) internal view returns (uint48) {
        return gasTestBase + uint48(adapterIdx);
    }

    function _poolId(uint16 centrifugeId, uint8 adapterIdx) internal view returns (PoolId) {
        uint48 poolIndex = _poolIndex(adapterIdx);
        return PoolId.wrap(uint64(centrifugeId) << 48 | poolIndex);
    }

    function _adapterName(AdapterType adapter) internal pure returns (string memory) {
        if (adapter == AdapterType.Axelar) return "Axelar";
        if (adapter == AdapterType.LayerZero) return "LayerZero";
        if (adapter == AdapterType.Wormhole) return "Wormhole";
        return "Chainlink";
    }

    function _adapterSymbol(AdapterType adapter) internal pure returns (string memory) {
        if (adapter == AdapterType.Axelar) return "AX";
        if (adapter == AdapterType.LayerZero) return "LZ";
        if (adapter == AdapterType.Wormhole) return "WH";
        return "CL";
    }

    //----------------------------------------------------------------------------------------------
    // LOGGING
    //----------------------------------------------------------------------------------------------

    function _logPoolSetupComplete() internal view {
        console.log("\n=== Phase 1 Complete: Pool Setup ===");
        console.log("\nPools created on hub (no XC messages sent):");
        _logPoolIds();
        console.log("\nNEXT STEP:");
        console.log("  Run runAdapterSetup() to configure adapters and notify pools");
        console.log("  Example: forge script ... --sig 'runAdapterSetup()'");
    }

    function _logAdapterSetupComplete() internal view {
        console.log("\n=== Phase 2 Complete: Adapter Setup ===");
        console.log("\nAdapters configured and NotifyPool sent for:");
        _logPoolIds();
        console.log("\nXC messages sent per adapter:");
        console.log("  - SetPoolAdapters (configures isolated adapter on spoke)");
        console.log("  - NotifyPool (creates pool on spoke)");
        console.log("\nNEXT STEPS:");
        console.log("1. Wait for XC relay (~5-10 min)");
        console.log("   Monitor: https://testnet.axelarscan.io");
        console.log("\n2. Verify pool exists on spoke:");
        console.log(
            string.concat(
                "   cast call $SPOKE 'isPoolActive(uint64)(bool)' <POOL_ID> --rpc-url $", _envRpcName(spokeNetworkName)
            )
        );
        console.log("\n3. Run runShareClassTest() to test NotifyShareClass:");
        console.log("   forge script ... --sig 'runShareClassTest()'");
    }

    function _logShareClassTestComplete() internal pure {
        console.log("\n=== Phase 3 Complete: Share Class Test ===");
        console.log("\nNotifyShareClass messages sent via isolated adapters.");
        console.log("\nThis phase is REPEATABLE - run again to add more share classes.");
        console.log("\nMonitor XC relay:");
        console.log("  - Axelar: https://testnet.axelarscan.io");
        console.log("  - LayerZero: https://testnet.layerzeroscan.com");
        console.log("  - Wormhole: https://wormholescan.io/#/?network=TESTNET");
        console.log("  - Chainlink: Check CCIP explorer");
    }

    function _logPoolIds() internal view {
        string[4] memory adapterNames = ["Axelar", "LayerZero", "Wormhole", "Chainlink"];

        for (uint8 i = 0; i < ADAPTER_COUNT; i++) {
            if (!_shouldTestAdapter(i)) continue;
            uint48 poolIndex = _poolIndex(i);
            PoolId poolId = _poolId(hubCentrifugeId, i);
            console.log(
                string.concat("  - ", adapterNames[i], ": poolIndex=", vm.toString(poolIndex)),
                "poolId=",
                vm.toString(abi.encode(poolId))
            );
        }
    }

    function _envRpcName(string memory networkName) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(networkName));
        if (h == keccak256("arbitrum-sepolia")) return "ARBITRUM_SEPOLIA_RPC";
        if (h == keccak256("base-sepolia")) return "BASE_SEPOLIA_RPC";
        return "RPC_URL";
    }
}

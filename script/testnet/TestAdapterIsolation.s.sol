// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTestData} from "./BaseTestData.s.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AccountId} from "../../src/core/types/AccountId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";
import {ShareClassId, newShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IHubRequestManager} from "../../src/core/hub/interfaces/IHubRequestManager.sol";

import {ISyncManager} from "../../src/vaults/interfaces/IVaultManagers.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title TestAdapterIsolation
 * @notice Hub-side script to create isolated adapter test pools using Hub.setAdapters()
 * @dev This script creates pools with per-pool adapter configuration, eliminating the need
 *      for the AdapterTestSpell. It operates in two phases:
 *
 *      PHASE 1 (runPhase1_Setup): Create pools + configure adapters
 *      - Creates 6 pools (3 adapters × 2 vault types, Chainlink skipped)
 *      - Configures isolated adapters via hub.setAdapters()
 *      - Sends SetPoolAdapters messages cross-chain to configure spoke
 *
 *      PHASE 2 (runPhase2_Operations): Send pool operations (after relay)
 *      - Sends NotifyPool, NotifyShareClass, UpdateVault, etc.
 *      - These messages now route through the isolated adapter
 *
 *      Pool ID Schema (DETERMINISTIC):
 *      - Axelar Async:    poolIndex = 90000
 *      - Axelar Sync:     poolIndex = 90001
 *      - LayerZero Async: poolIndex = 90010
 *      - LayerZero Sync:  poolIndex = 90011
 *      - Wormhole Async:  poolIndex = 90020
 *      - Wormhole Sync:   poolIndex = 90021
 *
 * Usage:
 *   # Phase 1: Create pools + configure adapters
 *   NETWORK=base-sepolia forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
 *     --sig "runPhase1_Setup()" --rpc-url $BASE_SEPOLIA_RPC --broadcast -vvvv
 *
 *   # Wait for cross-chain relay of SetPoolAdapters messages
 *
 *   # Phase 2: Send pool operations
 *   NETWORK=base-sepolia forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
 *     --sig "runPhase2_Operations()" --rpc-url $BASE_SEPOLIA_RPC --broadcast -vvvv
 */
contract TestAdapterIsolation is BaseTestData {
    using CastLib for address;

    //----------------------------------------------------------------------------------------------
    // CONSTANTS
    //----------------------------------------------------------------------------------------------

    uint256 constant POOL_SUBSIDY = 0.1 ether;
    uint256 constant TEST_USDC_MINT_AMOUNT = 100_000_000e6;
    uint48 constant DEFAULT_ADAPTER_TEST_BASE = 90000;

    address constant ARBITRUM_SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // Chainlink (index 3) requires special handling due to CCIP gas limits.
    // Messages are sent in sequential smaller batches to stay under the per-message gas limit.
    // See README.md for details on Chainlink testing workflow.
    uint8 constant ADAPTER_COUNT = 4; // 0=Axelar, 1=LayerZero, 2=Wormhole, 3=Chainlink
    uint8 constant POOL_TYPES = 2;

    uint256 constant ASYNC_VAULT_XC_MSG_COUNT = 8;
    uint256 constant SYNC_VAULT_XC_MSG_COUNT = 9;

    //----------------------------------------------------------------------------------------------
    // TYPES
    //----------------------------------------------------------------------------------------------

    enum AdapterType {
        Axelar,
        LayerZero,
        Wormhole,
        Chainlink
    }

    enum PoolType {
        Async,
        Sync
    }

    struct PoolCore {
        PoolId poolId;
        ShareClassId scId;
        uint16 targetCentrifugeId;
        AssetId assetId;
    }

    //----------------------------------------------------------------------------------------------
    // STORAGE
    //----------------------------------------------------------------------------------------------

    address public admin;
    uint16 public hubCentrifugeId;
    uint16 public spokeCentrifugeId;
    string public spokeNetworkName;
    uint48 public adapterTestBase;

    uint8 internal selectedAdapter = 255; // 255 = all adapters

    //----------------------------------------------------------------------------------------------
    // ENTRY POINTS
    //----------------------------------------------------------------------------------------------

    function run() public override {
        runPhase1_Setup();
    }

    function runPhase1_Setup() public {
        _loadConfig();
        _loadAdapterSelection();
        _logConfig();
        _logPoolIdReference();

        console.log("\n=== PHASE 1: Pool Creation + Adapter Configuration ===\n");

        vm.startBroadcast();
        _phase1_CreatePoolsAndConfigureAdapters();
        vm.stopBroadcast();

        _logPhase1Complete();
    }

    /// @notice Register asset only - run this on the SPOKE chain for cross-chain setups
    /// @dev After running this, wait for XC relay, then run Phase 1 on hub with SKIP_ASSET_REGISTRATION=true
    ///
    ///      Required env vars:
    ///        NETWORK=arbitrum-sepolia (the spoke chain you're running on)
    ///        HUB_NETWORK=base-sepolia (the hub chain to send registration to)
    ///        TEST_USDC_ADDRESS=0x... (USDC address on this spoke chain)
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
        console.log("Current network:", network);
        console.log("Local CentrifugeId:", localCentrifugeId);
        console.log("Target Hub CentrifugeId:", targetHubCentrifugeId);

        AssetId assetId = newAssetId(localCentrifugeId, 1);

        address localUsdc;
        try vm.envAddress("TEST_USDC_ADDRESS") returns (address addr) {
            localUsdc = addr;
        } catch {
            console.log("\n[ERROR] TEST_USDC_ADDRESS env var required!");
            console.log("        Find USDC on your testnet and set it:");
            console.log("        TEST_USDC_ADDRESS=0x... forge script ...");
            revert("TEST_USDC_ADDRESS required for spoke-side asset registration");
        }

        console.log("\nLocal USDC address:", localUsdc);
        console.log("AssetId will be:", assetId.raw());

        vm.startBroadcast();
        spoke.registerAsset{value: xcGasPerCall}(targetHubCentrifugeId, localUsdc, 0, msg.sender);
        vm.stopBroadcast();

        console.log("\n[Asset] Registration XC message sent to hub!");
        console.log("        Wait for cross-chain relay, then run Phase 1 on hub:");
        console.log(
            "        NETWORK=base-sepolia SKIP_ASSET_REGISTRATION=true forge script ... --sig 'runPhase1_Setup()'"
        );
    }

    /// @notice Phase 2: Send pool operations after cross-chain adapter config is complete
    /// @dev Requires PRIVATE_KEY env var to be set for the pool manager
    function runPhase2_Operations() public {
        _loadConfig();
        _loadAdapterSelection();
        _logConfig();

        console.log("\n=== PHASE 2: Pool Operations (via isolated adapters) ===\n");

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        _phase2_SendPoolOperations();
        vm.stopBroadcast();

        _logPhase2Complete();
    }

    //----------------------------------------------------------------------------------------------
    // SINGLE ADAPTER ENTRY POINTS
    //----------------------------------------------------------------------------------------------

    function runAxelar_Setup() public {
        selectedAdapter = uint8(AdapterType.Axelar);
        runPhase1_Setup();
    }

    function runAxelar_Operations() public {
        selectedAdapter = uint8(AdapterType.Axelar);
        runPhase2_Operations();
    }

    function runLayerZero_Setup() public {
        selectedAdapter = uint8(AdapterType.LayerZero);
        runPhase1_Setup();
    }

    function runLayerZero_Operations() public {
        selectedAdapter = uint8(AdapterType.LayerZero);
        runPhase2_Operations();
    }

    function runWormhole_Setup() public {
        selectedAdapter = uint8(AdapterType.Wormhole);
        runPhase1_Setup();
    }

    function runWormhole_Operations() public {
        selectedAdapter = uint8(AdapterType.Wormhole);
        runPhase2_Operations();
    }

    function runChainlink_Setup() public {
        selectedAdapter = uint8(AdapterType.Chainlink);
        runPhase1_Setup();
    }

    function runChainlink_Operations() public {
        selectedAdapter = uint8(AdapterType.Chainlink);
        runPhase2_Operations();
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

        adapterTestBase = uint48(vm.envOr("ADAPTER_TEST_BASE", uint256(DEFAULT_ADAPTER_TEST_BASE)));

        loadContractsFromConfig(config);
    }

    function _logConfig() internal view {
        console.log("=== Adapter Isolation Test Configuration ===");
        console.log("Hub CentrifugeId:", hubCentrifugeId);
        console.log("Spoke CentrifugeId:", spokeCentrifugeId);
        console.log("Spoke Network:", spokeNetworkName);
        console.log("Admin:", admin);
        console.log("XC Gas Per Call:", xcGasPerCall);
        console.log("Adapter Test Base:", adapterTestBase);
        console.log("=============================================\n");
    }

    function _logPoolIdReference() internal view {
        console.log("=== POOL ID REFERENCE (DETERMINISTIC) ===");
        console.log("Pool IDs are deterministic based on ADAPTER_TEST_BASE:", adapterTestBase);
        console.log("To create fresh pools, set ADAPTER_TEST_BASE env var (increment by 100):\n");

        string[4] memory adapterNames = ["Axelar", "LayerZero", "Wormhole", "Chainlink"];
        string[2] memory poolTypes = ["Async", "Sync"];

        for (uint8 i = 0; i < ADAPTER_COUNT; i++) {
            for (uint8 j = 0; j < POOL_TYPES; j++) {
                uint48 poolIndex = _poolIndex(i, j);
                PoolId poolId = _poolId(hubCentrifugeId, i, j);
                console.log(
                    string.concat("  ", adapterNames[i], " ", poolTypes[j], ": index=", vm.toString(poolIndex)),
                    "poolId=",
                    vm.toString(abi.encode(poolId))
                );
            }
        }
        console.log("");
    }

    /// @notice Load adapter selection from ADAPTER env var
    /// @dev Supports: "axelar", "layerzero", "wormhole", "all" (default), or numeric index 0-2
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
    // PHASE 1: CREATE POOLS + CONFIGURE ADAPTERS
    //----------------------------------------------------------------------------------------------

    function _phase1_CreatePoolsAndConfigureAdapters() internal {
        (uint256 existing, uint256 total) = _countExistingPools();
        if (existing == total && total > 0) {
            console.log("\n[Phase1] All", total, "pools already exist - nothing to create");
            console.log("         To create fresh pools, set ADAPTER_TEST_BASE to a new value (e.g., 90100)");
            console.log("         Example: ADAPTER_TEST_BASE=90100 forge script ...");
            return;
        }
        if (existing > 0) {
            console.log("\n[Phase1] Partial state:", existing, "of", total);
            console.log("         pools exist - will create remaining pools");
        }

        AssetId assetId = newAssetId(spokeCentrifugeId, 1);
        _ensureAssetRegistered(spokeCentrifugeId, assetId);

        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            if (!_shouldTestAdapter(adapterIdx)) continue;
            _createPoolWithIsolatedAdapter(AdapterType(adapterIdx), PoolType.Async, assetId);
            _createPoolWithIsolatedAdapter(AdapterType(adapterIdx), PoolType.Sync, assetId);
        }
    }

    function _countExistingPools() internal view returns (uint256 existing, uint256 total) {
        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            if (!_shouldTestAdapter(adapterIdx)) continue;
            for (uint8 poolType = 0; poolType < POOL_TYPES; poolType++) {
                total++;
                PoolId poolId = _poolId(hubCentrifugeId, adapterIdx, poolType);
                if (hubRegistry.exists(poolId)) {
                    existing++;
                }
            }
        }
    }

    function _createPoolWithIsolatedAdapter(AdapterType adapter, PoolType poolType, AssetId assetId) internal {
        uint48 poolIndex = _poolIndex(uint8(adapter), uint8(poolType));
        PoolId poolId = hubRegistry.poolId(hubCentrifugeId, poolIndex);

        if (hubRegistry.exists(poolId)) {
            console.log("Pool already exists, skipping:", _adapterName(adapter), _poolTypeName(poolType));
            return;
        }

        console.log("\n--- Creating pool for:", _adapterName(adapter), _poolTypeName(poolType));
        console.log("    Pool Index:", poolIndex);

        bool isAsync = poolType == PoolType.Async;

        _createPoolBase(poolId);
        ShareClassId scId = _addShareClass(poolId, adapter, isAsync);
        _initializeHoldingAndPrice(poolId, scId, assetId);
        _setPoolMetadata(poolId, adapter, isAsync);
        _configureIsolatedAdapter(poolId, adapter);

        console.log("    PoolId:", vm.toString(abi.encode(poolId)));
        console.log("    ShareClassId:", vm.toString(abi.encode(scId)));
        console.log("    Adapter configured:", _adapterName(adapter));
    }

    function _configureIsolatedAdapter(PoolId poolId, AdapterType adapter) internal {
        IAdapter adapterInstance = _getAdapter(adapter);

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = adapterInstance;

        bytes32[] memory remoteAdapters = new bytes32[](1);
        remoteAdapters[0] = address(adapterInstance).toBytes32();

        hub.setAdapters{value: xcGasPerCall}(poolId, spokeCentrifugeId, localAdapters, remoteAdapters, 1, 0, msg.sender);

        console.log("    SetPoolAdapters sent to spoke centrifugeId:", spokeCentrifugeId);
    }

    //----------------------------------------------------------------------------------------------
    // PHASE 2: SEND POOL OPERATIONS
    //----------------------------------------------------------------------------------------------

    function _phase2_SendPoolOperations() internal {
        AssetId assetId = newAssetId(spokeCentrifugeId, 1);

        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            if (!_shouldTestAdapter(adapterIdx)) continue;
            _sendPoolOperationsForAdapter(AdapterType(adapterIdx), PoolType.Async, assetId);
            _sendPoolOperationsForAdapter(AdapterType(adapterIdx), PoolType.Sync, assetId);
        }
    }

    function _sendPoolOperationsForAdapter(AdapterType adapter, PoolType poolType, AssetId assetId) internal {
        uint48 poolIndex = _poolIndex(uint8(adapter), uint8(poolType));
        PoolId poolId = hubRegistry.poolId(hubCentrifugeId, poolIndex);

        if (!hubRegistry.exists(poolId)) {
            console.log("Pool does not exist, skipping:", _adapterName(adapter), _poolTypeName(poolType));
            return;
        }

        ShareClassId scId = _findExistingShareClass(poolId);

        console.log("\n--- Sending operations for:", _adapterName(adapter), _poolTypeName(poolType));

        bool isAsync = poolType == PoolType.Async;
        PoolCore memory core = PoolCore(poolId, scId, spokeCentrifugeId, assetId);
        bytes[] memory calls = isAsync ? _buildAsyncVaultCalls(core) : _buildSyncVaultCalls(core);
        uint256 batchMsgCount = isAsync ? ASYNC_VAULT_XC_MSG_COUNT : SYNC_VAULT_XC_MSG_COUNT;

        hub.multicall{value: xcGasPerCall * batchMsgCount}(calls);

        console.log(
            string.concat(
                "    Sent ", vm.toString(batchMsgCount), " XC messages via ", _adapterName(adapter), " adapter"
            )
        );
    }

    //----------------------------------------------------------------------------------------------
    // POOL CREATION HELPERS
    //----------------------------------------------------------------------------------------------

    function _createPoolBase(PoolId poolId) internal {
        subsidyManager.deposit{value: POOL_SUBSIDY}(poolId);
        opsGuardian.createPool(poolId, msg.sender, USD_ID);

        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), true);
    }

    function _addShareClass(PoolId poolId, AdapterType adapter, bool isAsync) internal returns (ShareClassId scId) {
        scId = shareClassManager.previewNextShareClassId(poolId);
        string memory adapterName = _adapterName(adapter);
        string memory typeStr = isAsync ? "Async" : "Sync";
        string memory shareName = string.concat("Adapter-", adapterName, "-", typeStr);
        string memory shareSymbol = string.concat("AD", _adapterSymbol(adapter), isAsync ? "A" : "S");
        bytes32 shareClassMeta =
            bytes32(abi.encodePacked(bytes8(poolId.raw()), bytes24(keccak256(abi.encodePacked(adapterName, typeStr)))));
        hub.addShareClass(poolId, shareName, shareSymbol, shareClassMeta);
    }

    function _initializeHoldingAndPrice(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
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
    }

    function _setPoolMetadata(PoolId poolId, AdapterType adapter, bool isAsync) internal {
        string memory adapterName = _adapterName(adapter);
        string memory typeStr = isAsync ? "Async" : "Sync";
        string memory poolMeta = string.concat("Adapter-Test-", adapterName, "-", typeStr);
        hub.setPoolMetadata(poolId, bytes(poolMeta));
    }

    //----------------------------------------------------------------------------------------------
    // MULTICALL BUILDERS
    //----------------------------------------------------------------------------------------------

    function _buildCommonCalls(PoolCore memory c, bytes[] memory calls) internal view {
        calls[0] = abi.encodeCall(hub.notifyPool, (c.poolId, c.targetCentrifugeId, address(0)));
        calls[1] = abi.encodeCall(
            hub.notifyShareClass,
            (c.poolId, c.scId, c.targetCentrifugeId, address(redemptionRestrictionsHook).toBytes32(), address(0))
        );
        calls[2] = abi.encodeCall(
            hub.setRequestManager,
            (
                c.poolId,
                c.targetCentrifugeId,
                IHubRequestManager(batchRequestManager),
                address(asyncRequestManager).toBytes32(),
                address(0)
            )
        );
        calls[3] = abi.encodeCall(
            hub.updateBalanceSheetManager,
            (c.poolId, c.targetCentrifugeId, address(asyncRequestManager).toBytes32(), true, address(0))
        );
    }

    function _buildPriceCalls(PoolCore memory c, bytes[] memory calls, uint256 startIdx) internal view {
        calls[startIdx] = abi.encodeCall(hub.notifySharePrice, (c.poolId, c.scId, c.targetCentrifugeId, address(0)));
        calls[startIdx + 1] = abi.encodeCall(hub.notifyAssetPrice, (c.poolId, c.scId, c.assetId, address(0)));
    }

    function _buildAsyncVaultCalls(PoolCore memory c) internal view returns (bytes[] memory) {
        bytes[] memory calls = new bytes[](ASYNC_VAULT_XC_MSG_COUNT);

        _buildCommonCalls(c, calls);

        calls[4] = abi.encodeCall(
            hub.updateBalanceSheetManager, (c.poolId, c.targetCentrifugeId, admin.toBytes32(), true, address(0))
        );
        calls[5] = abi.encodeCall(
            hub.updateVault,
            (
                c.poolId,
                c.scId,
                c.assetId,
                address(asyncVaultFactory).toBytes32(),
                VaultUpdateKind.DeployAndLink,
                0,
                address(0)
            )
        );

        _buildPriceCalls(c, calls, 6);

        return calls;
    }

    function _buildSyncVaultCalls(PoolCore memory c) internal view returns (bytes[] memory) {
        bytes[] memory calls = new bytes[](SYNC_VAULT_XC_MSG_COUNT);

        _buildCommonCalls(c, calls);

        calls[4] = abi.encodeCall(
            hub.updateBalanceSheetManager,
            (c.poolId, c.targetCentrifugeId, address(syncManager).toBytes32(), true, address(0))
        );
        calls[5] = abi.encodeCall(
            hub.updateVault,
            (
                c.poolId,
                c.scId,
                c.assetId,
                address(syncDepositVaultFactory).toBytes32(),
                VaultUpdateKind.DeployAndLink,
                0,
                address(0)
            )
        );

        _buildPriceCalls(c, calls, 6);

        calls[8] = abi.encodeCall(
            hub.updateContract,
            (
                c.poolId,
                c.scId,
                c.targetCentrifugeId,
                address(syncManager).toBytes32(),
                abi.encode(uint8(ISyncManager.TrustedCall.MaxReserve), c.assetId.raw(), type(uint128).max),
                0,
                address(0)
            )
        );

        return calls;
    }

    //----------------------------------------------------------------------------------------------
    // UTILITIES
    //----------------------------------------------------------------------------------------------

    /// @notice Find an existing share class for the pool
    function _findExistingShareClass(PoolId poolId) internal view returns (ShareClassId) {
        ShareClassId nextScId = shareClassManager.previewNextShareClassId(poolId);
        uint32 nextIndex = nextScId.index();

        for (uint32 i = 0; i < nextIndex && i < 10; i++) {
            ShareClassId scId = newShareClassId(poolId, i);
            if (shareClassManager.exists(poolId, scId)) {
                console.log("    Found existing share class at index:", i);
                return scId;
            }
        }

        console.log("    WARNING: No existing share class found, using index 0");
        return newShareClassId(poolId, 0);
    }

    /// @notice Ensure asset is registered, handling various edge cases for frictionless re-runs
    /// @dev For cross-chain setups, asset registration must happen from the SPOKE chain
    function _ensureAssetRegistered(uint16 targetCentrifugeId, AssetId assetId) internal {
        if (hubRegistry.isRegistered(assetId)) {
            console.log("[Asset] Already registered on Hub, assetId:", assetId.raw());
            return;
        }

        if (_anyTestPoolExists()) {
            console.log("[Asset] Test pool exists, asset registration must be pending/complete");
            console.log("        Wait for XC relay or check spoke for asset registration");
            return;
        }

        bool isCrossChain = targetCentrifugeId != hubCentrifugeId;
        if (isCrossChain) {
            console.log("[Asset] CROSS-CHAIN DETECTED: Hub=", hubCentrifugeId, "Spoke=", targetCentrifugeId);
            console.log("");
            console.log("        Asset registration must happen from the SPOKE chain.");
            console.log("        The spoke.registerAsset() function validates the token locally,");
            console.log("        so the token must exist on the chain where the call is made.");
            console.log("");
            console.log("        Options:");
            console.log("        1. Run this script on the SPOKE network to register asset first:");
            console.log("           NETWORK=arbitrum-sepolia forge script ... --sig 'registerAssetOnly()'");
            console.log("");
            console.log("        2. Use SKIP_ASSET_REGISTRATION=true if asset already registered:");
            console.log("           SKIP_ASSET_REGISTRATION=true forge script ...");
            console.log("");

            bool skipAssetReg = vm.envOr("SKIP_ASSET_REGISTRATION", false);
            if (skipAssetReg) {
                console.log("        SKIP_ASSET_REGISTRATION=true, continuing without asset registration...");
                return;
            }

            revert("Cross-chain asset registration not supported from hub. See options above.");
        }

        address usdcAddress = _resolveUsdcAddress(targetCentrifugeId);
        spoke.registerAsset{value: xcGasPerCall}(targetCentrifugeId, usdcAddress, 0, msg.sender);
        console.log("[Asset] Registered asset locally:", usdcAddress);
        console.log("        AssetId:", assetId.raw());
    }

    function _anyTestPoolExists() internal view returns (bool) {
        for (uint8 adapterIdx = 0; adapterIdx < ADAPTER_COUNT; adapterIdx++) {
            for (uint8 poolType = 0; poolType < POOL_TYPES; poolType++) {
                PoolId poolId = _poolId(hubCentrifugeId, adapterIdx, poolType);
                if (hubRegistry.exists(poolId)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// @notice Resolve USDC address to use for asset registration
    /// @dev Priority: TEST_USDC_ADDRESS env > known testnet USDC > deploy new (if allowed)
    function _resolveUsdcAddress(uint16 targetCentrifugeId) internal returns (address) {
        try vm.envAddress("TEST_USDC_ADDRESS") returns (address addr) {
            console.log("[Asset] Using TEST_USDC_ADDRESS from env:", addr);
            return addr;
        } catch {}

        address knownUsdc = _getKnownUsdcForChain(targetCentrifugeId);
        if (knownUsdc != address(0)) {
            console.log("[Asset] Using known testnet USDC for chain", targetCentrifugeId, ":", knownUsdc);
            return knownUsdc;
        }

        bool allowDeploy = vm.envOr("DEPLOY_NEW_USDC", false);
        if (!allowDeploy) {
            revert("No known USDC for target chain. Set TEST_USDC_ADDRESS or DEPLOY_NEW_USDC=true");
        }

        console.log("[Asset] Deploying new test USDC (DEPLOY_NEW_USDC=true)");
        ERC20 usdc = new ERC20(6);
        usdc.file("name", "USD Coin");
        usdc.file("symbol", "USDC");
        usdc.mint(msg.sender, TEST_USDC_MINT_AMOUNT);
        console.log("[Asset] Deployed new USDC at:", address(usdc));
        return address(usdc);
    }

    function _getKnownUsdcForChain(uint16 centrifugeId) internal pure returns (address) {
        if (centrifugeId == 2) return BASE_SEPOLIA_USDC;
        if (centrifugeId == 3) return ARBITRUM_SEPOLIA_USDC;
        return address(0);
    }

    function _getAdapter(AdapterType adapter) internal view returns (IAdapter) {
        if (adapter == AdapterType.Axelar) return axelarAdapter;
        if (adapter == AdapterType.LayerZero) return layerZeroAdapter;
        if (adapter == AdapterType.Wormhole) return wormholeAdapter;
        return chainlinkAdapter;
    }

    function _poolIndex(uint8 adapterIdx, uint8 poolType) internal view returns (uint48) {
        return adapterTestBase + uint48(adapterIdx) * 10 + poolType;
    }

    function _poolId(uint16 centrifugeId, uint8 adapterIdx, uint8 poolType) internal view returns (PoolId) {
        uint48 poolIndex = _poolIndex(adapterIdx, poolType);
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

    function _poolTypeName(PoolType poolType) internal pure returns (string memory) {
        return poolType == PoolType.Async ? "Async" : "Sync";
    }

    //----------------------------------------------------------------------------------------------
    // LOGGING
    //----------------------------------------------------------------------------------------------

    function _logPhase1Complete() internal view {
        console.log("\n=== Phase 1 Complete! ===");
        console.log("\nPools created with isolated adapter configuration:");
        console.log(
            string.concat(
                "  - Axelar:    poolIndex ",
                vm.toString(adapterTestBase),
                " (Async), ",
                vm.toString(adapterTestBase + 1),
                " (Sync)"
            )
        );
        console.log(
            string.concat(
                "  - LayerZero: poolIndex ",
                vm.toString(adapterTestBase + 10),
                " (Async), ",
                vm.toString(adapterTestBase + 11),
                " (Sync)"
            )
        );
        console.log(
            string.concat(
                "  - Wormhole:  poolIndex ",
                vm.toString(adapterTestBase + 20),
                " (Async), ",
                vm.toString(adapterTestBase + 21),
                " (Sync)"
            )
        );
        console.log(
            string.concat(
                "\nSetPoolAdapters messages sent to spoke (centrifugeId: ", vm.toString(spokeCentrifugeId), ")"
            )
        );
        console.log("\nNEXT STEPS:");
        console.log("1. Wait for cross-chain relay of SetPoolAdapters messages");
        console.log("   Monitor: https://testnet.axelarscan.io (SetPoolAdapters uses global adapters)");
        console.log("\n2. Verify adapter config on spoke:");
        console.log(
            "   cast call $MULTI_ADAPTER 'quorum(uint16,uint64)(uint8)' <HUB_CID> <POOL_ID> --rpc-url $SPOKE_RPC"
        );
        console.log("\n3. Run Phase 2 to send pool operations:");
        console.log("   NETWORK=base-sepolia forge script ... --sig 'runPhase2_Operations()'");
    }

    function _logPhase2Complete() internal view {
        console.log("\n=== Phase 2 Complete! ===");
        console.log("\nPool operations sent via isolated adapters:");
        console.log("  - Each pool's messages route through its configured adapter only");
        console.log("\nNEXT STEPS:");
        console.log("1. Monitor cross-chain relay for each adapter:");
        console.log("   - Axelar: https://testnet.axelarscan.io");
        console.log("   - LayerZero: https://testnet.layerzeroscan.com");
        console.log("   - Wormhole: https://wormholescan.io/#/?network=TESTNET");
        console.log(string.concat("\n2. Verify pools on spoke: ", spokeNetworkName));
        console.log("   cast call $HUB_REGISTRY 'exists(uint64)(bool)' <POOL_ID> --rpc-url $SPOKE_RPC");
    }
}

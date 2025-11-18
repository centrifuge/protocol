// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTestData} from "./BaseTestData.s.sol";

import {ERC20} from "../../src/misc/ERC20.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title TestCrossChainHub
 * @notice Hub-side script to create cross-chain test pools
 * @dev This script runs on the HUB chain and creates pools for each connected spoke chain.
 *      It sends cross-chain messages to configure vaults on spoke chains.
 *
 *      This script is designed to be run multiple times with different pool indices
 *      to allow testing adapters/bridges repeatedly with fresh pools.
 *
 * Prerequisites:
 *   - Run deploy.py dump for the hub network to set environment variables
 *   - Ensure PROTOCOL_ADMIN is set
 *
 * Configuration (optional env vars):
 *   POOL_INDEX_OFFSET - Offset to add to pool indices (default: current timestamp % 1000)
 *   TEST_RUN_ID - Custom identifier for this test run (used in pool metadata)
 *
 * Usage:
 *   cd script/deploy && python deploy.py dump sepolia && cd ../..
 *   source env/latest/11155111-latest.json
 *
 *   # First run (uses timestamp-based offset)
 *   forge script script/crosschain/TestCrossChainHub.s.sol:TestCrossChainHub \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     -vvvv
 *
 *   # Subsequent runs with custom offset to avoid conflicts
 *   export POOL_INDEX_OFFSET=500
 *   export TEST_RUN_ID="adapter-test-1"
 *   forge script script/crosschain/TestCrossChainHub.s.sol:TestCrossChainHub \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     -vvvv
 *
 * What it does:
 *   1. Reads the hub network configuration
 *   2. For each connected network in "connectsTo" array:
 *      - Creates an async vault pool with unique index
 *      - Creates a sync deposit vault pool with unique index
 *   3. Sends cross-chain messages to deploy vaults on spoke chains
 *
 * Next steps:
 *   - Wait for messages to relay (2-5 minutes)
 *   - Run TestCrossChainSpoke with matching POOL_INDEX_OFFSET on each spoke chain
 */
contract TestCrossChainHub is BaseTestData {
    address public admin;
    uint16 public hubCentrifugeId;
    string[] public connectedNetworks;
    uint64 public poolIndexOffset;
    string public testRunId;

    function run() public override {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        hubCentrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));

        // Parse connected networks
        bytes memory connectsToRaw = vm.parseJson(config, "$.network.connectsTo");
        connectedNetworks = abi.decode(connectsToRaw, (string[]));

        // Get pool index offset (default: timestamp % 1000 for uniqueness)
        poolIndexOffset = uint64(vm.envOr("POOL_INDEX_OFFSET", uint256(block.timestamp % 1000)));

        // Get test run ID (default: timestamp-based)
        testRunId = vm.envOr("TEST_RUN_ID", vm.toString(block.timestamp));

        // Resolve admin with fallback to broadcaster if PROTOCOL_ADMIN not set
        address maybeAdmin = address(0);
        try vm.envAddress("PROTOCOL_ADMIN") returns (address a) {
            maybeAdmin = a;
        } catch {}
        admin = (maybeAdmin != address(0)) ? maybeAdmin : msg.sender;

        console.log("=== Cross-Chain Hub Test Configuration ===");
        console.log("Hub Network:", network);
        console.log("Hub centrifugeId:", hubCentrifugeId);
        console.log("Pool Index Offset:", poolIndexOffset);
        console.log("Test Run ID:", testRunId);
        console.log("Admin (PROTOCOL_ADMIN or broadcaster):", admin);
        console.log("Connected networks:", connectedNetworks.length);
        for (uint256 i = 0; i < connectedNetworks.length; i++) {
            console.log("  -", connectedNetworks[i]);
        }
        console.log("=========================================\n");
        loadContractsFromConfig(config);

        vm.startBroadcast();
        _setupCrossChainPools();
        vm.stopBroadcast();
    }

    function _setupCrossChainPools() internal {
        console.log("\n=== Creating Cross-Chain Pools ===\n");

        // Create pools for each connected network in a separate stack frame
        for (uint256 i = 0; i < connectedNetworks.length; i++) {
            _processNetwork(connectedNetworks[i]);
        }

        console.log("\n=== Cross-Chain Pool Setup Complete ===");
        console.log("\nNext steps:");
        console.log("1. Wait for cross-chain messages to relay (10-20 minutes)");
        console.log("2. Monitor message relayers:");
        console.log("   - Axelar: https://testnet.axelarscan.io");
        console.log("   - Wormhole: https://wormholescan.io");
        console.log("   - LayerZero: https://testnet.layerzeroscan.com");
        console.log("3. Run TestCrossChainSpoke on each spoke chain:");
        console.log("   cd script/deploy && python deploy.py dump <spoke-network> && cd ../..");
        console.log("   export HUB_CENTRIFUGE_ID=%s", hubCentrifugeId);
        console.log("   export POOL_INDEX_OFFSET=%s", poolIndexOffset);
        console.log("   export TEST_RUN_ID=%s", testRunId);
        console.log(
            "   forge script script/crosschain/TestCrossChainSpoke.s.sol:TestCrossChainSpoke --rpc-url $RPC_URL -vvvv"
        );
    }

    function _processNetwork(string memory spokeNetworkName) internal {
        string memory spokeConfigFile = string.concat("env/", spokeNetworkName, ".json");
        string memory spokeConfig = vm.readFile(spokeConfigFile);
        uint16 spokeCentrifugeId = uint16(vm.parseJsonUint(spokeConfig, "$.network.centrifugeId"));

        console.log("\n--- Setting up pools for:", spokeNetworkName);
        console.log("centrifugeId:", spokeCentrifugeId);

        // Compute the canonical assetId for this network
        AssetId assetId = newAssetId(spokeCentrifugeId, 1);

        // If asset is not registered yet, deploy a fresh USDC and register it for the spoke
        address usdcAddr = address(0);
        if (!hubRegistry.isRegistered(assetId)) {
            ERC20 usdc = new ERC20(6);
            usdc.file("name", "USD Coin");
            usdc.file("symbol", "USDC");
            usdc.mint(msg.sender, 100_000_000e6);
            usdcAddr = address(usdc);
            console.log("Deployed test USDC:", usdcAddr);

            // Register asset for this spoke chain
            if (xcGasPerCall == 0) {
                xcGasPerCall = vm.envOr("XC_GAS_PER_CALL", DEFAULT_XC_GAS_PER_CALL);
            }
            spoke.registerAsset{value: xcGasPerCall}(spokeCentrifugeId, usdcAddr, 0, msg.sender);
            console.log("Registered asset ID:", assetId.raw());
        } else {
            console.log("Asset already registered for spoke centrifugeId:", spokeCentrifugeId);
        }

        // Determine deterministic pool indices (uint48 per HubRegistry API)
        uint48 asyncPoolIndex = uint48(uint64(spokeCentrifugeId) * 1000 + poolIndexOffset * 2 + 1);
        uint48 syncPoolIndex = uint48(uint64(spokeCentrifugeId) * 1000 + poolIndexOffset * 2 + 2);

        // Compute PoolIds on hub (pools created on hub, spoke learns via notifyPool)
        PoolId asyncPoolId = hubRegistry.poolId(hubCentrifugeId, asyncPoolIndex);
        PoolId syncPoolId = hubRegistry.poolId(hubCentrifugeId, syncPoolIndex);

        bool asyncExists = hubRegistry.exists(asyncPoolId);
        bool syncExists = hubRegistry.exists(syncPoolId);

        // Create async vault pool if not present
        if (!asyncExists) {
            ERC20 usdcForAsync = usdcAddr != address(0) ? ERC20(usdcAddr) : ERC20(address(0));
            _createAsyncVaultPool(spokeCentrifugeId, spokeNetworkName, usdcForAsync, assetId);
        } else {
            console.log("Async pool already exists, skipping:", vm.toString(abi.encode(asyncPoolId)));
        }

        // Create sync deposit vault pool if not present
        if (!syncExists) {
            ERC20 usdcForSync = usdcAddr != address(0) ? ERC20(usdcAddr) : ERC20(address(0));
            _createSyncDepositVaultPool(spokeCentrifugeId, spokeNetworkName, usdcForSync, assetId);
        } else {
            console.log("Sync pool already exists, skipping:", vm.toString(abi.encode(syncPoolId)));
        }
    }

    function _createAsyncVaultPool(
        uint16 spokeCentrifugeId,
        string memory spokeNetworkName,
        ERC20 token,
        AssetId assetId
    ) internal {
        // Pool index: (spokeCentrifugeId * 1000) + poolIndexOffset*2 + 1
        // This ensures unique pools for each test run
        uint48 asyncPoolIndex = uint48(uint64(spokeCentrifugeId) * 1000 + poolIndexOffset * 2 + 1);

        console.log("Creating async pool, poolIndex:", asyncPoolIndex);

        string memory shareName = string.concat("XC-Async-", spokeNetworkName, "-", testRunId);
        string memory shareSymbol = string.concat("XCA", vm.toString(poolIndexOffset));
        string memory poolMeta = string.concat("XC Async [", testRunId, "] - ", spokeNetworkName);

        (PoolId poolId, ShareClassId scId) = deployAsyncVaultXc(
            XcAsyncVaultParams({
                hubCentrifugeId: hubCentrifugeId,
                targetCentrifugeId: spokeCentrifugeId,
                poolIndex: asyncPoolIndex,
                token: token,
                assetId: assetId,
                admin: admin,
                poolMetadata: poolMeta,
                shareClassName: shareName,
                shareClassSymbol: shareSymbol,
                // Unique salt per run to avoid collisions across repeated tests
                shareClassMeta: keccak256(abi.encodePacked("XC-ASYNC", spokeCentrifugeId, poolIndexOffset, testRunId))
            })
        );

        console.log("  Created PoolId:", vm.toString(abi.encode(poolId)));
        console.log("  ShareClassId:", vm.toString(abi.encode(scId)));
        console.log("  Cross-chain messages sent to spokeCentrifugeId:", spokeCentrifugeId);
    }

    function _createSyncDepositVaultPool(
        uint16 spokeCentrifugeId,
        string memory spokeNetworkName,
        ERC20 token,
        AssetId assetId
    ) internal {
        // Pool index: (spokeCentrifugeId * 1000) + poolIndexOffset*2 + 2
        // This ensures unique pools for each test run
        uint48 syncPoolIndex = uint48(uint64(spokeCentrifugeId) * 1000 + poolIndexOffset * 2 + 2);

        console.log("Creating sync pool, poolIndex:", syncPoolIndex);

        string memory shareName = string.concat("XC-Sync-", spokeNetworkName, "-", testRunId);
        string memory shareSymbol = string.concat("XCS", vm.toString(poolIndexOffset));
        string memory poolMeta = string.concat("XC Sync [", testRunId, "] - ", spokeNetworkName);

        (PoolId poolId, ShareClassId scId) = deploySyncDepositVaultXc(
            XcSyncVaultParams({
                hubCentrifugeId: hubCentrifugeId,
                targetCentrifugeId: spokeCentrifugeId,
                poolIndex: syncPoolIndex,
                token: token,
                assetId: assetId,
                admin: admin,
                poolMetadata: poolMeta,
                shareClassName: shareName,
                shareClassSymbol: shareSymbol,
                shareClassMeta: keccak256(abi.encodePacked("XC-SYNC", spokeCentrifugeId, poolIndexOffset, testRunId))
            })
        );

        console.log("  Created PoolId:", vm.toString(abi.encode(poolId)));
        console.log("  ShareClassId:", vm.toString(abi.encode(scId)));
        console.log("  Cross-chain messages sent to spokeCentrifugeId:", spokeCentrifugeId);
    }
}

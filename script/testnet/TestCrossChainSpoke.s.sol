// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTestData} from "./BaseTestData.s.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {IShareToken} from "../../src/core/spoke/interfaces/IShareToken.sol";
import {ShareClassId, newShareClassId} from "../../src/core/types/ShareClassId.sol";

import {UpdateRestrictionMessageLib} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {SyncDepositVault} from "../../src/vaults/SyncDepositVault.sol";
import {IAsyncVault} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Script.sol";

/**
 * @title TestCrossChainSpoke
 * @notice Spoke-side script to interact with cross-chain vaults
 * @dev This script runs on a SPOKE chain to interact with vaults that were deployed
 *      via cross-chain messages from the hub.
 *
 * Prerequisites:
 *   - TestCrossChainHub has been run on the hub chain
 *   - Cross-chain messages have been relayed and processed
 *   - Set HUB_CENTRIFUGE_ID and POOL_INDEX_OFFSET environment variables
 *
 * Configuration (env vars):
 *   HUB_CENTRIFUGE_ID - The centrifugeId of the hub chain (required)
 *   POOL_INDEX_OFFSET - Must match the offset used in TestCrossChainHub (default: 0)
 *   TEST_RUN_ID - The test run identifier (optional, for logging)
 *
 * Usage:
 *   cd script/deploy && python deploy.py dump base-sepolia && cd ../..
 *   source env/latest/84532-latest.json
 *   export HUB_CENTRIFUGE_ID=1
 *   export POOL_INDEX_OFFSET=123  # Must match hub script
 *   export TEST_RUN_ID="adapter-test-1"  # Optional
 *   forge script script/crosschain/TestCrossChainSpoke.s.sol:TestCrossChainSpoke \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     -vvvv
 *
 * What it does:
 *   1. Calculates pool IDs using the same offset as hub
 *   2. Verifies that pools and vaults exist on the spoke chain
 *   3. Performs test operations on async and sync vaults
 *   4. Tests deposit, withdrawal, and other vault interactions
 */
contract TestCrossChainSpoke is BaseTestData {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    address public admin;
    uint16 public spokeCentrifugeId;
    uint16 public hubCentrifugeId;
    uint64 public poolIndexOffset;
    string public testRunId;

    function run() public override {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        spokeCentrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        hubCentrifugeId = uint16(vm.envUint("HUB_CENTRIFUGE_ID"));

        // Must match the values used in TestCrossChainHub
        poolIndexOffset = uint64(vm.envOr("POOL_INDEX_OFFSET", uint256(0)));
        testRunId = vm.envOr("TEST_RUN_ID", string("default"));

        console.log("=== Cross-Chain Spoke Test Configuration ===");
        console.log("Spoke Network:", network);
        console.log("Spoke centrifugeId:", spokeCentrifugeId);
        console.log("Hub centrifugeId:", hubCentrifugeId);
        console.log("Pool Index Offset:", poolIndexOffset);
        console.log("Test Run ID:", testRunId);
        console.log("==========================================\n");

        admin = vm.envAddress("PROTOCOL_ADMIN");
        loadContractsFromConfig(config);

        vm.startBroadcast();
        _testSpokeVaults();
        vm.stopBroadcast();
    }

    function _testSpokeVaults() internal {
        console.log("\n=== Testing Spoke Vaults ===\n");

        // Calculate pool IDs using the same pattern as hub script
        // Pool index: (spokeCentrifugeId * 1000) + poolIndexOffset*2 + {1,2}
        uint64 asyncPoolIndex = uint64(spokeCentrifugeId) * 1000 + poolIndexOffset * 2 + 1;
        uint64 syncPoolIndex = uint64(spokeCentrifugeId) * 1000 + poolIndexOffset * 2 + 2;

        PoolId asyncPoolId = hubRegistry.poolId(spokeCentrifugeId, uint48(asyncPoolIndex));
        PoolId syncPoolId = hubRegistry.poolId(spokeCentrifugeId, uint48(syncPoolIndex));

        console.log("Looking for async pool, poolIndex:", asyncPoolIndex);
        console.log("  PoolId:", vm.toString(abi.encode(asyncPoolId)));

        console.log("Looking for sync pool, poolIndex:", syncPoolIndex);
        console.log("  PoolId:", vm.toString(abi.encode(syncPoolId)));

        // Get the first share class ID for each pool
        // Note: We can use shareClassManager to get the next ID, then subtract 1
        // But since we know it's the first share class, we can calculate it
        ShareClassId asyncScId = newShareClassId(asyncPoolId, 1);
        ShareClassId syncScId = newShareClassId(syncPoolId, 1);

        console.log("  Async ShareClassId:", vm.toString(abi.encode(asyncScId)));
        console.log("  Sync ShareClassId:", vm.toString(abi.encode(syncScId)));

        // Try to get share tokens to verify pools exist
        address asyncShareToken = address(spoke.shareToken(asyncPoolId, asyncScId));
        address syncShareToken = address(spoke.shareToken(syncPoolId, syncScId));

        if (asyncShareToken != address(0)) {
            console.log("\n[SUCCESS] Async pool found!");
            console.log("  ShareToken:", asyncShareToken);
            _testAsyncVault(asyncShareToken);
        } else {
            console.log("\n[WAITING] Async pool not yet available");
            console.log("  Messages may still be in transit");
            console.log("  Check message relay status and try again in a few minutes");
        }

        if (syncShareToken != address(0)) {
            console.log("\n[SUCCESS] Sync pool found!");
            console.log("  ShareToken:", syncShareToken);
            _testSyncVault(syncShareToken);
        } else {
            console.log("\n[WAITING] Sync pool not yet available");
            console.log("  Messages may still be in transit");
            console.log("  Check message relay status and try again in a few minutes");
        }

        console.log("\n=== Spoke Test Complete ===");
    }

    function _testAsyncVault(address shareTokenAddress) internal {
        console.log("\n--- Testing Async Vault ---");

        IShareToken shareToken = IShareToken(shareTokenAddress);

        // Get asset ID
        AssetId assetId = newAssetId(spokeCentrifugeId, 1);

        // Get USDC address - it should have been registered on this spoke
        (address usdcAddress,) = spoke.idToAsset(assetId);

        if (usdcAddress == address(0)) {
            console.log("[ERROR] USDC not registered on spoke chain for assetId:", assetId.raw());
            return;
        }

        console.log("  USDC address:", usdcAddress);
        ERC20 usdc = ERC20(usdcAddress);

        // Get vault
        address vaultAddress = shareToken.vault(usdcAddress);
        if (vaultAddress == address(0)) {
            console.log("[ERROR] Vault not found for USDC");
            return;
        }

        console.log("  Vault address:", vaultAddress);
        IAsyncVault vault = IAsyncVault(vaultAddress);

        // Check if we have USDC balance
        uint256 balance = usdc.balanceOf(msg.sender);
        console.log("  USDC balance:", balance);

        if (balance < 100_000e6) {
            console.log("[WARNING] Insufficient USDC balance for testing");
            console.log("  Skipping vault interactions");
            return;
        }

        // Test deposit request
        console.log("  Testing deposit request...");
        uint256 depositAmount = 10_000e6;
        usdc.approve(address(vault), depositAmount);
        vault.requestDeposit(depositAmount, msg.sender, msg.sender);
        console.log("  [OK] Deposit request submitted:", depositAmount);

        // Note: Fulfillment requires hub-side operations (manager approval)
        console.log("  To fulfill: Run hub operations to approve and issue shares");
    }

    function _testSyncVault(address shareTokenAddress) internal {
        console.log("\n--- Testing Sync Vault ---");

        IShareToken shareToken = IShareToken(shareTokenAddress);

        // Get asset ID
        AssetId assetId = newAssetId(spokeCentrifugeId, 1);

        // Get USDC address
        (address usdcAddress,) = spoke.idToAsset(assetId);

        if (usdcAddress == address(0)) {
            console.log("[ERROR] USDC not registered on spoke chain for assetId:", assetId.raw());
            return;
        }

        console.log("  USDC address:", usdcAddress);
        ERC20 usdc = ERC20(usdcAddress);

        // Get vault
        address vaultAddress = shareToken.vault(usdcAddress);
        if (vaultAddress == address(0)) {
            console.log("[ERROR] Vault not found for USDC");
            return;
        }

        console.log("  Vault address:", vaultAddress);
        SyncDepositVault vault = SyncDepositVault(vaultAddress);

        // Check if we have USDC balance
        uint256 balance = usdc.balanceOf(msg.sender);
        console.log("  USDC balance:", balance);

        if (balance < 100_000e6) {
            console.log("[WARNING] Insufficient USDC balance for testing");
            console.log("  Skipping vault interactions");
            return;
        }

        // Test deposit (sync vaults allow immediate deposits if configured)
        console.log("  Testing sync deposit...");
        uint256 depositAmount = 5_000e6;
        usdc.approve(address(vault), depositAmount);

        try vault.deposit(depositAmount, msg.sender) {
            console.log("  [OK] Sync deposit successful:", depositAmount);
        } catch {
            console.log("  [INFO] Sync deposit may require additional configuration");
            console.log("  Vault may need max reserve setting or other permissions");
        }
    }
}

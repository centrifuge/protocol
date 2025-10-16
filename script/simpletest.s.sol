// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
import {OpsGuardian} from "../src/admin/OpsGuardian.sol";
import {Hub} from "../src/core/hub/Hub.sol";
import {PoolId} from "../src/core/types/PoolId.sol";
import {AssetId, newAssetId} from "../src/core/types/AssetId.sol";
import {HubRegistry} from "../src/core/hub/HubRegistry.sol";
import "forge-std/Script.sol";
contract TestCrossChain is Script {
    OpsGuardian opsGuardian;
    Hub hub;
    HubRegistry hubRegistry;
    
    address admin;
    uint16 localCentrifugeId;
    
    function run() public {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);
        
        opsGuardian = OpsGuardian(vm.parseJsonAddress(config, "$.contracts.opsGuardian"));
        hub = Hub(vm.parseJsonAddress(config, "$.contracts.hub"));
        hubRegistry = HubRegistry(vm.parseJsonAddress(config, "$.contracts.hubRegistry"));
        
        localCentrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        admin = vm.envAddress("ADMIN");
        
        console.log("=== Cross-Chain Test ===");
        console.log("Network:", network);
        console.log("CentrifugeId:", localCentrifugeId);
        
        vm.startBroadcast();
        
        if (localCentrifugeId == 1) {
            _testEthereumSepolia();
        } else {
            console.log("Run this script on Ethereum Sepolia (centrifugeId: 1)");
        }
        
        vm.stopBroadcast();
    }
    
    function _testEthereumSepolia() internal {
        // Generate a pseudo-random 3-digit pool index (100-999), allow override via POOL_INDEX
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, blockhash(block.number - 1), tx.origin)));
        uint256 defaultIdx = 100 + (seed % 900);
        uint64 poolIndex = uint64(vm.envOr("POOL_INDEX", defaultIdx));
        if (poolIndex < 100) {
            poolIndex = 100;
        } else if (poolIndex > 999) {
            poolIndex = 999;
        }

        PoolId poolId = hubRegistry.poolId(localCentrifugeId, uint48(poolIndex));
        console.log("Using poolIndex:", poolIndex);
        console.log("PoolId:", vm.toString(abi.encode(poolId)));
        
        console.log("Creating pool...");
        AssetId usdId = newAssetId(840);
        opsGuardian.createPool(poolId, msg.sender, usdId);
        console.log("SUCCESS: Pool created");
        
        console.log("Sending cross-chain notification to Base Sepolia...");
        hub.notifyPool{value: 0.1 ether}(poolId, 3, admin);
        hub.notifyPool{value: 0.1 ether}(poolId, 2, admin);
        console.log("SUCCESS: Cross-chain notification sent");
    }
}
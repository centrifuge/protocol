// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import {HubDeployer} from "script/HubDeployer.s.sol";
import {CommonInput} from "script/CommonDeployer.s.sol";
import {ExtendedSpokeDeployer} from "script/ExtendedSpokeDeployer.s.sol";

import "forge-std/Script.sol";

contract FullDeployer is HubDeployer, ExtendedSpokeDeployer {
    function deployFull(CommonInput memory input, address deployer) public {
        deployHub(input, deployer);
        deployExtendedSpoke(input, deployer);
    }

    function removeFullDeployerAccess(address deployer) public {
        removeHubDeployerAccess(deployer);
        removeExtendedSpokeDeployerAccess(deployer);
    }

    function run() public virtual {
        vm.startBroadcast();
        uint16 centrifugeId;
        string memory environment;
        string memory network;

        try vm.envString("NETWORK") returns (string memory _network) {
            network = _network;
            string memory configFile = string.concat("env/", network, ".json");
            string memory config = vm.readFile(configFile);
            centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
            environment = vm.parseJsonString(config, "$.network.environment");
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
            revert("NETWORK environment variable is required");
        }

        console.log("Network:", network);
        console.log("Environment:", environment);

        CommonInput memory input = CommonInput({
            centrifugeId: centrifugeId,
            adminSafe: ISafe(vm.envAddress("ADMIN")),
            messageGasLimit: uint128(vm.envUint("MESSAGE_COST")),
            maxBatchSize: uint128(vm.envUint("MAX_BATCH_SIZE")),
            isTests: false
        });

        // Use the regular deployment functions - they now use CreateX internally
        deployFull(input, msg.sender);

        // Since `wire()` is not called, separately adding the safe here
        guardian.file("safe", address(adminSafe));
        saveDeploymentOutput();

        bool isNotMainnet = keccak256(abi.encodePacked(environment)) != keccak256(abi.encodePacked("mainnet"));

        if (!isNotMainnet) {
            removeFullDeployerAccess(msg.sender);
        }

        vm.stopBroadcast();
    }
}

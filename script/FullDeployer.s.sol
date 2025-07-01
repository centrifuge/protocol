// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {HubCBD, HubDeployer} from "script/HubDeployer.s.sol";
import {ExtendedSpokeCBD, ExtendedSpokeDeployer} from "script/ExtendedSpokeDeployer.s.sol";

import "forge-std/Script.sol";
import {ICreateX} from "createx-forge/script/ICreateX.sol";

contract FullCBD is HubCBD, ExtendedSpokeCBD {
    function deployFull(CommonInput memory input, ICreateX createX, address deployer) public {
        deployHub(input, createX, deployer);
        deployExtendedSpoke(input, createX, deployer);
    }

    function removeFullDeployerAccess(address deployer) public {
        removeHubDeployerAccess(deployer);
        removeExtendedSpokeDeployerAccess(deployer);
    }
}

contract FullDeployer is HubDeployer, ExtendedSpokeDeployer, FullCBD {
    function deployFull(CommonInput memory input, address deployer) public {
        super.deployFull(input, _createX(), deployer);
    }

    function fullRegister() internal {
        hubRegister();
        extendedSpokeRegister();
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
        console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));

        CommonInput memory input = CommonInput({
            centrifugeId: centrifugeId,
            root: IRoot(vm.envAddress("ROOT")),
            adminSafe: ISafe(vm.envAddress("ADMIN")),
            messageGasLimit: uint128(vm.envUint("MESSAGE_COST")),
            maxBatchSize: uint128(vm.envUint("MAX_BATCH_SIZE")),
            version: vm.envOr("VERSION", bytes32(0))
        });

        deployFull(input, msg.sender);

        startDeploymentOutput();
        fullRegister();
        saveDeploymentOutput();

        bool isMainnet = keccak256(abi.encodePacked(environment)) == keccak256(abi.encodePacked("mainnet"));
        if (isMainnet) {
            removeFullDeployerAccess(msg.sender);
        } else {
            guardian.file("safe", address(adminSafe));
        }

        vm.stopBroadcast();
    }
}

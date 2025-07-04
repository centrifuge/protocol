// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {HubDeployer, HubActionBatcher} from "script/HubDeployer.s.sol";
import {ExtendedSpokeDeployer, ExtendedSpokeActionBatcher} from "script/ExtendedSpokeDeployer.s.sol";

import "forge-std/Script.sol";

/**
 * @title FullDeployer
 * @notice Deploys the complete Centrifuge protocol stack (Hub + Spoke)
 */
contract FullActionBatcher is HubActionBatcher, ExtendedSpokeActionBatcher {}

contract FullDeployer is HubDeployer, ExtendedSpokeDeployer {
    // Config variables
    uint256 public batchGasLimit;

    function deployFull(CommonInput memory input, FullActionBatcher batcher) public {
        _preDeployFull(input, batcher);
        _postDeployFull(batcher);
    }

    function _preDeployFull(CommonInput memory input, FullActionBatcher batcher) internal {
        _preDeployHub(input, batcher);
        _preDeployExtendedSpoke(input, batcher);
    }

    function _postDeployFull(FullActionBatcher batcher) internal {
        _postDeployHub(batcher);
        _postDeployExtendedSpoke(batcher);
    }

    function removeFullDeployerAccess(FullActionBatcher batcher) public {
        removeHubDeployerAccess(batcher);
        removeExtendedSpokeDeployerAccess(batcher);
    }

    function run() public virtual {
        vm.startBroadcast();
        uint16 centrifugeId;
        string memory environment;
        string memory network;
        address rootAddress;

        try vm.envString("NETWORK") returns (string memory _network) {
            network = _network;
            string memory configFile = string.concat("env/", network, ".json");
            string memory config = vm.readFile(configFile);
            centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
            environment = vm.parseJsonString(config, "$.network.environment");

            try vm.parseJsonAddress(config, "$.network.root") returns (address _root) {
                rootAddress = _root;
            } catch {
                rootAddress = address(0);
            }

            // Parse batchGasLimit with defaults
            try vm.parseJsonUint(config, "$.network.batchGasLimit") returns (uint256 _batchGasLimit) {
                batchGasLimit = _batchGasLimit;
            } catch {
                batchGasLimit = 25_000_000; // 25M gas
            }
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
            revert("NETWORK environment variable is required");
        }

        console.log("Network:", network);
        console.log("Environment:", environment);
        console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));

        startDeploymentOutput();

        CommonInput memory input = CommonInput({
            centrifugeId: centrifugeId,
            root: IRoot(rootAddress),
            adminSafe: ISafe(vm.envAddress("ADMIN")),
            batchGasLimit: uint128(batchGasLimit),
            version: vm.envOr("VERSION", bytes32(0))
        });

        FullActionBatcher batcher = new FullActionBatcher();
        deployFull(input, batcher);

        bool isMainnet = keccak256(abi.encodePacked(environment)) == keccak256(abi.encodePacked("mainnet"));
        if (isMainnet) {
            removeFullDeployerAccess(batcher);
        }

        batcher.lock();

        saveDeploymentOutput();

        vm.stopBroadcast();
    }
}

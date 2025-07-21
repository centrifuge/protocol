// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {HubDeployer, HubActionBatcher} from "./HubDeployer.s.sol";
import {ExtendedSpokeDeployer, ExtendedSpokeActionBatcher} from "./ExtendedSpokeDeployer.s.sol";
import { WormholeInput, AxelarInput, AdaptersInput, AdaptersDeployer, AdaptersActionBatcher } from "./AdaptersDeployer.s.sol";

import {ISafe} from "../src/common/interfaces/IGuardian.sol";

import "forge-std/Script.sol";

contract FullActionBatcher is HubActionBatcher, ExtendedSpokeActionBatcher, AdaptersActionBatcher {}

/**
 * @title FullDeployer
 * @notice Deploys the complete Centrifuge protocol stack (Hub + Spoke + Adapters)
 */
contract FullDeployer is HubDeployer, ExtendedSpokeDeployer, AdaptersDeployer {
    // Config variables
    uint256 public batchGasLimit;

    function deployFull(CommonInput memory commonInput, AdaptersInput memory adaptersInput, FullActionBatcher batcher)
        public
    {
        _preDeployFull(commonInput, adaptersInput, batcher);
        _postDeployFull(batcher);
    }

    function _preDeployFull(
        CommonInput memory commonInput,
        AdaptersInput memory adaptersInput,
        FullActionBatcher batcher
    ) internal {
        _preDeployHub(commonInput, batcher);
        _preDeployExtendedSpoke(commonInput, batcher);
        _preDeployAdapters(commonInput, adaptersInput, batcher);
    }

    function _postDeployFull(FullActionBatcher batcher) internal {
        _postDeployHub(batcher);
        _postDeployExtendedSpoke(batcher);
        _postDeployAdapters(batcher);
    }

    function removeFullDeployerAccess(FullActionBatcher batcher) public {
        removeHubDeployerAccess(batcher);
        removeExtendedSpokeDeployerAccess(batcher);
        removeAdaptersDeployerAccess(batcher);
    }

    function run() public virtual {
        vm.startBroadcast();

        string memory network;
        string memory config;
        try vm.envString("NETWORK") returns (string memory _network) {
            network = _network;
            string memory configFile = string.concat("env/", network, ".json");
            config = vm.readFile(configFile);
        } catch {
            console.log("NETWORK environment variable is not set, this must be a mocked test");
            revert("NETWORK environment variable is required");
        }

        uint16 centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));
        string memory environment = vm.parseJsonString(config, "$.network.environment");

        // Parse batchGasLimit with defaults
        try vm.parseJsonUint(config, "$.network.batchGasLimit") returns (uint256 _batchGasLimit) {
            batchGasLimit = _batchGasLimit;
        } catch {
            batchGasLimit = 25_000_000; // 25M gas
        }

        console.log("Network:", network);
        console.log("Environment:", environment);
        console.log("Version:", vm.envOr("VERSION", string("")));
        console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));

        startDeploymentOutput();

        CommonInput memory commonInput = CommonInput({
            centrifugeId: centrifugeId,
            adminSafe: ISafe(vm.envAddress("ADMIN")),
            batchGasLimit: uint128(batchGasLimit),
            version: keccak256(abi.encodePacked(vm.envOr("VERSION", string(""))))
        });

        AdaptersInput memory adaptersInput = AdaptersInput({
            wormhole: WormholeInput({
                shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.wormhole.deploy"),
                relayer: _parseJsonAddressOrDefault(config, "$.adapters.wormhole.relayer")
            }),
            axelar: AxelarInput({
                shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.axelar.deploy"),
                gateway: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gateway"),
                gasService: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gasService")
            })
        });

        FullActionBatcher batcher = new FullActionBatcher();
        deployFull(commonInput, adaptersInput, batcher);

        removeFullDeployerAccess(batcher);

        batcher.lock();

        saveDeploymentOutput();

        vm.stopBroadcast();
    }

    function _parseJsonBoolOrDefault(string memory config, string memory path) private pure returns (bool) {
        try vm.parseJsonBool(config, path) returns (bool value) {
            return value;
        } catch {
            return false;
        }
    }

    function _parseJsonAddressOrDefault(string memory config, string memory path) private pure returns (address) {
        try vm.parseJsonAddress(config, path) returns (address value) {
            return value;
        } catch {
            return address(0);
        }
    }
}

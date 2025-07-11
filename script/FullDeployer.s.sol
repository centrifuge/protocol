// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {HubDeployer, HubActionBatcher} from "script/HubDeployer.s.sol";
import {ExtendedSpokeDeployer, ExtendedSpokeActionBatcher} from "script/ExtendedSpokeDeployer.s.sol";
import {
    WormholeInput,
    AxelarInput,
    AdaptersInput,
    AdaptersDeployer,
    AdaptersActionBatcher
} from "script/AdaptersDeployer.s.sol";

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
        console.log("Version:", vm.envOr("VERSION", string("")));
        console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));

        startDeploymentOutput();

        CommonInput memory commonInput = CommonInput({
            centrifugeId: centrifugeId,
            root: IRoot(rootAddress),
            adminSafe: ISafe(vm.envAddress("ADMIN")),
            batchGasLimit: uint128(batchGasLimit),
            version: keccak256(abi.encodePacked(vm.envOr("VERSION", string(""))))
        });

        AdaptersInput memory adaptersInput = AdaptersInput({
            wormhole: WormholeInput({
                shouldDeploy: true, // TODO
                relayer: address(0) // TODO
            }),
            axelar: AxelarInput({
                shouldDeploy: true, // TODO
                gateway: address(0), // TODO
                gasService: address(0) // TODO
            })
        });

        FullActionBatcher batcher = FullActionBatcher(
            create3(
                keccak256(abi.encodePacked("fullActionBatcher", commonInput.version)),
                abi.encodePacked(type(FullActionBatcher).creationCode)
            )
        );
        deployFull(commonInput, adaptersInput, batcher);

        bool isMainnet = keccak256(abi.encodePacked(environment)) == keccak256(abi.encodePacked("mainnet"));
        if (isMainnet) {
            removeFullDeployerAccess(batcher);
        }

        batcher.lock();

        saveDeploymentOutput();

        vm.stopBroadcast();
    }
}

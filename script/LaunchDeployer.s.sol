// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreInput} from "./CoreDeployer.s.sol";
import {EnvConfig, Env, prettyEnvString} from "./utils/EnvConfig.s.sol";
import {
    FullInput,
    FullDeployer,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    AdapterConnections
} from "./FullDeployer.s.sol";

import {CastLib} from "../src/misc/libraries/CastLib.sol";

import {ISafe} from "../src/admin/interfaces/ISafe.sol";

import "forge-std/Script.sol";

contract LaunchDeployer is FullDeployer {
    using CastLib for *;

    function run() public virtual {
        vm.startBroadcast();
        captureStartBlock();
        startDeploymentOutput();

        EnvConfig memory config = Env.load(prettyEnvString("NETWORK"));
        bytes32 version = prettyEnvString("VERSION").toBytes32();

        FullInput memory input = _buildFullInput(config, version);
        deployFull(input, msg.sender);
        removeFullDeployerAccess();

        // Hardcoded wards to double-check a correct mainnet deployment
        if (config.network.isMainnet()) {
            require(address(input.protocolSafe) == 0x9711730060C73Ee7Fcfe1890e8A0993858a7D225, "wrong safe admin");
            require(address(input.opsSafe) == 0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16, "wrong ops admin");
            require(msg.sender == 0x926702C7f1af679a8f99A40af8917DDd82fD6F6c, "wrong deployer");
        }

        saveDeploymentOutput();
        vm.stopBroadcast();
    }

    function _buildFullInput(EnvConfig memory config, bytes32 version) internal view returns (FullInput memory) {
        return FullInput({
            protocolSafe: ISafe(config.network.protocolAdmin),
            opsSafe: ISafe(config.network.opsAdmin),
            core: CoreInput({
                centrifugeId: config.network.centrifugeId, version: version, txLimits: config.network.buildBatchLimits()
            }),
            adapters: AdaptersInput({
                layerZero: LayerZeroInput({
                    shouldDeploy: config.adapters.layerZero.deploy,
                    endpoint: config.adapters.layerZero.endpoint,
                    delegate: config.network.protocolAdmin,
                    configParams: config.buildLayerZeroConfigParams()
                }),
                wormhole: WormholeInput({
                    shouldDeploy: config.adapters.wormhole.deploy, relayer: config.adapters.wormhole.relayer
                }),
                axelar: AxelarInput({
                    shouldDeploy: config.adapters.axelar.deploy,
                    gateway: config.adapters.axelar.gateway,
                    gasService: config.adapters.axelar.gasService
                }),
                chainlink: ChainlinkInput({
                    shouldDeploy: config.adapters.chainlink.deploy, ccipRouter: config.adapters.chainlink.ccipRouter
                }),
                connections: _buildConnections(config)
            })
        });
    }

    function _buildConnections(EnvConfig memory config)
        internal
        view
        returns (AdapterConnections[] memory connections)
    {
        string[] memory connectsTo = config.network.connectsTo;
        connections = new AdapterConnections[](connectsTo.length);

        for (uint256 i; i < connectsTo.length; i++) {
            EnvConfig memory remoteConfig = Env.load(connectsTo[i]);

            connections[i] = AdapterConnections({
                centrifugeId: remoteConfig.network.centrifugeId,
                layerZeroId: remoteConfig.adapters.layerZero.layerZeroEid,
                wormholeId: remoteConfig.adapters.wormhole.wormholeId,
                axelarId: remoteConfig.adapters.axelar.axelarId,
                chainlinkId: remoteConfig.adapters.chainlink.chainSelector,
                threshold: remoteConfig.adapters.threshold
            });
        }
    }
}

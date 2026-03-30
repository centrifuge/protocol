// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {Env, EnvConfig} from "./utils/EnvConfig.s.sol";

import {CastLib} from "../src/misc/libraries/CastLib.sol";

import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";

string constant V3_1 = "v3.1";

/// @title DeployAdapters
/// @notice Deploys only messaging adapters, reusing existing core addresses from env/<network>.json
contract DeployAdapters is BaseDeployer {
    using CastLib for *;

    function run() public {
        EnvConfig memory config = Env.load(vm.envString("NETWORK"));

        vm.startBroadcast();
        startDeploymentOutput();

        _init(vm.envOr("SUFFIX", string("")), msg.sender);

        if (config.adapters.wormhole.deploy) {
            WormholeAdapter wormholeAdapter = WormholeAdapter(
                create3(
                    createSalt("wormholeAdapter", V3_1),
                    abi.encodePacked(
                        type(WormholeAdapter).creationCode,
                        abi.encode(config.contracts.multiAdapter, config.adapters.wormhole.relayer, msg.sender)
                    )
                )
            );
            wormholeAdapter.rely(config.contracts.root);
            wormholeAdapter.rely(config.contracts.protocolGuardian);
            wormholeAdapter.rely(config.contracts.opsGuardian);
            wormholeAdapter.deny(msg.sender);
        }

        if (config.adapters.axelar.deploy) {
            AxelarAdapter axelarAdapter = AxelarAdapter(
                create3(
                    createSalt("axelarAdapter", V3_1),
                    abi.encodePacked(
                        type(AxelarAdapter).creationCode,
                        abi.encode(
                            config.contracts.multiAdapter,
                            config.adapters.axelar.gateway,
                            config.adapters.axelar.gasService,
                            msg.sender
                        )
                    )
                )
            );
            axelarAdapter.rely(config.contracts.root);
            axelarAdapter.rely(config.contracts.protocolGuardian);
            axelarAdapter.rely(config.contracts.opsGuardian);
            axelarAdapter.deny(msg.sender);
        }

        if (config.adapters.layerZero.deploy) {
            LayerZeroAdapter layerZeroAdapter = LayerZeroAdapter(
                create3(
                    createSalt("layerZeroAdapter", V3_1),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        abi.encode(
                            config.contracts.multiAdapter,
                            config.adapters.layerZero.endpoint,
                            config.network.protocolAdmin,
                            msg.sender
                        )
                    )
                )
            );
            layerZeroAdapter.rely(config.contracts.root);
            layerZeroAdapter.rely(config.contracts.protocolGuardian);
            layerZeroAdapter.rely(config.contracts.opsGuardian);
            layerZeroAdapter.rely(config.network.protocolAdmin);
            layerZeroAdapter.deny(msg.sender);
        }

        if (config.adapters.chainlink.deploy) {
            ChainlinkAdapter chainlinkAdapter = ChainlinkAdapter(
                create3(
                    createSalt("chainlinkAdapter", V3_1),
                    abi.encodePacked(
                        type(ChainlinkAdapter).creationCode,
                        abi.encode(config.contracts.multiAdapter, config.adapters.chainlink.ccipRouter, msg.sender)
                    )
                )
            );
            chainlinkAdapter.rely(config.contracts.root);
            chainlinkAdapter.rely(config.contracts.protocolGuardian);
            chainlinkAdapter.rely(config.contracts.opsGuardian);
            chainlinkAdapter.deny(msg.sender);
        }

        saveDeploymentOutput();
        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreDeployer} from "./CoreDeployer.s.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import {CastLib} from "../src/misc/libraries/CastLib.sol";

import {MultiAdapter} from "../src/core/messaging/MultiAdapter.sol";

import "forge-std/Script.sol";

import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";

/// @title OnlyAdapters
/// @notice Deploys only messaging adapters, reusing existing core addresses from env/<network>.json
contract OnlyAdapters is Script, JsonRegistry, CoreDeployer {
    using CastLib for *;

    WormholeAdapter public wormholeAdapter;
    AxelarAdapter public axelarAdapter;
    LayerZeroAdapter public layerZeroAdapter;

    function _fetchConfig(string memory network) internal view returns (string memory) {
        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);
        return config;
    }

    function run() public {
        string memory network = vm.envString("NETWORK");
        string memory config = _fetchConfig(network);

        // Set version deterministically like LaunchDeployer
        version = vm.envOr("VERSION", string("")).toBytes32();
        setUpCreateXFactory();
        // Load core addresses we need
        address multiAdapterAddr = vm.parseJsonAddress(config, "$.contracts.multiAdapter");
        address protocolGuardianAddr = vm.parseJsonAddress(config, "$.contracts.protocolGuardian");
        address opsGuardianAddr = vm.parseJsonAddress(config, "$.contracts.opsGuardian");
        address rootAddr = vm.parseJsonAddress(config, "$.contracts.root");

        multiAdapter = MultiAdapter(multiAdapterAddr);

        // Read adapter toggles
        bool deployWormhole = false;
        bool deployAxelar = false;
        bool deployLayerZero = false;
        try vm.parseJsonBool(config, "$.adapters.wormhole.deploy") returns (bool v1) {
            deployWormhole = v1;
        } catch {}
        try vm.parseJsonBool(config, "$.adapters.axelar.deploy") returns (bool v2) {
            deployAxelar = v2;
        } catch {}
        try vm.parseJsonBool(config, "$.adapters.layerZero.deploy") returns (bool v3) {
            deployLayerZero = v3;
        } catch {}

        address deployerEOA = tx.origin; // the broadcaster EOA becomes initial ward

        startDeploymentOutput();

        vm.startBroadcast();

        if (deployWormhole) {
            address wormholeRelayer = vm.parseJsonAddress(config, "$.adapters.wormhole.relayer");
            require(wormholeRelayer != address(0), "Wormhole relayer address cannot be zero");
            require(wormholeRelayer.code.length > 0, "Wormhole relayer must be a deployed contract");

            wormholeAdapter = WormholeAdapter(
                create3(
                    generateSalt("wormholeAdapter"),
                    abi.encodePacked(
                        type(WormholeAdapter).creationCode, abi.encode(multiAdapter, wormholeRelayer, deployerEOA)
                    )
                )
            );
            wormholeAdapter.rely(rootAddr);
            wormholeAdapter.rely(protocolGuardianAddr);
            wormholeAdapter.rely(opsGuardianAddr);
            register("wormholeAdapter", address(wormholeAdapter));
        }

        if (deployAxelar) {
            address axelarGateway = vm.parseJsonAddress(config, "$.adapters.axelar.gateway");
            address axelarGasService = vm.parseJsonAddress(config, "$.adapters.axelar.gasService");
            require(axelarGateway != address(0), "Axelar gateway address cannot be zero");
            require(axelarGasService != address(0), "Axelar gas service address cannot be zero");
            require(axelarGateway.code.length > 0, "Axelar gateway must be a deployed contract");
            require(axelarGasService.code.length > 0, "Axelar gas service must be a deployed contract");

            axelarAdapter = AxelarAdapter(
                create3(
                    generateSalt("axelarAdapter"),
                    abi.encodePacked(
                        type(AxelarAdapter).creationCode,
                        abi.encode(multiAdapter, axelarGateway, axelarGasService, deployerEOA)
                    )
                )
            );
            axelarAdapter.rely(rootAddr);
            axelarAdapter.rely(protocolGuardianAddr);
            axelarAdapter.rely(opsGuardianAddr);
            register("axelarAdapter", address(axelarAdapter));
        }

        if (deployLayerZero) {
            address lzEndpoint = vm.parseJsonAddress(config, "$.adapters.layerZero.endpoint");
            address lzDelegate = vm.envAddress("PROTOCOL_ADMIN");
            require(lzEndpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(lzEndpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(lzDelegate != address(0), "LayerZero delegate address cannot be zero");

            layerZeroAdapter = LayerZeroAdapter(
                create3(
                    generateSalt("layerZeroAdapter"),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        abi.encode(multiAdapter, lzEndpoint, lzDelegate, deployerEOA)
                    )
                )
            );
            layerZeroAdapter.rely(rootAddr);
            layerZeroAdapter.rely(protocolGuardianAddr);
            layerZeroAdapter.rely(opsGuardianAddr);
            register("layerZeroAdapter", address(layerZeroAdapter));
        }

        saveDeploymentOutput();

        vm.stopBroadcast();
    }
}

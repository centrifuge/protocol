// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreInput, makeSalt} from "./CoreDeployer.s.sol";
import {
    FullInput,
    FullActionBatcher,
    FullDeployer,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    AdapterConnections,
    MAX_ADAPTER_COUNT
} from "./FullDeployer.s.sol";

import {CastLib} from "../src/misc/libraries/CastLib.sol";
import {MathLib} from "../src/misc/libraries/MathLib.sol";

import {ISafe} from "../src/admin/interfaces/ISafe.sol";

import "forge-std/Script.sol";

contract LaunchDeployer is FullDeployer {
    using CastLib for *;
    using MathLib for *;

    function run() public virtual {
        vm.startBroadcast();
        captureStartBlock();

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
        bool isTestnet = keccak256(bytes(environment)) == keccak256("testnet");

        console.log("Network:", network);
        console.log("Environment:", environment);

        bytes32 version = vm.envOr("VERSION", string("")).toBytes32();
        console.log("Version:", version.toString());
        console.log("\n\n---------\n\nStarting deployment for chain ID: %s\n\n", vm.toString(block.chainid));

        startDeploymentOutput();

        uint8[32] memory txLimits;
        try vm.envUint("TX_LIMITS", ",") returns (uint256[] memory txLimitsRaw) {
            require(txLimitsRaw.length < 32, "only 32 tx limits supported");
            for (uint256 i; i < txLimitsRaw.length; i++) {
                txLimits[i] = txLimitsRaw[i].toUint8();
            }
        } catch {}

        FullInput memory input = FullInput({
            adminSafe: ISafe(vm.envAddress("PROTOCOL_ADMIN")),
            opsSafe: ISafe(vm.envAddress("OPS_ADMIN")),
            core: CoreInput({
                centrifugeId: centrifugeId, version: version, root: vm.envOr("ROOT", address(0)), txLimits: txLimits
            }),
            adapters: AdaptersInput({
                wormhole: WormholeInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.wormhole.deploy"),
                    relayer: _parseJsonAddressOrDefault(config, "$.adapters.wormhole.relayer")
                }),
                axelar: AxelarInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.axelar.deploy"),
                    gateway: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gateway"),
                    gasService: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gasService")
                }),
                layerZero: LayerZeroInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.layerZero.deploy"),
                    endpoint: _parseJsonAddressOrDefault(config, "$.adapters.layerZero.endpoint"),
                    delegate: vm.envAddress("PROTOCOL_ADMIN")
                }),
                chainlink: ChainlinkInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.chainlink.deploy"),
                    ccipRouter: _parseJsonAddressOrDefault(config, "$.adapters.chainlink.ccipRouter")
                }),
                connections: _parseConnections(config)
            })
        });

        FullActionBatcher batcher = FullActionBatcher(
            create3(
                makeSalt("fullActionBatcher", input.core.version, msg.sender),
                abi.encodePacked(type(FullActionBatcher).creationCode, abi.encode(msg.sender))
            )
        );

        deployFull(input, batcher);

        removeFullDeployerAccess(batcher);

        batcher.lock();

        saveDeploymentOutput();

        // Hardcoded wards to double-check a correct mainnet deployment
        if (!isTestnet) {
            require(address(input.adminSafe) == 0x9711730060C73Ee7Fcfe1890e8A0993858a7D225, "wrong safe admin");
            require(address(input.opsSafe) == 0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16, "wrong ops admin");
            require(msg.sender == 0x926702C7f1af679a8f99A40af8917DDd82fD6F6c, "wrong deployer");
        }

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

    function _parseJsonUintOrDefault(string memory config, string memory path) private pure returns (uint256) {
        try vm.parseJsonUint(config, path) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    function _parseJsonStringOrDefault(string memory config, string memory path) private pure returns (string memory) {
        try vm.parseJsonString(config, path) returns (string memory value) {
            return value;
        } catch {
            return "";
        }
    }

    function _parseConnections(string memory config) private view returns (AdapterConnections[] memory connections) {
        try vm.parseJsonStringArray(config, "$.network.connectsTo") returns (string[] memory connectsTo) {
            connections = new AdapterConnections[](connectsTo.length);

            for (uint256 i; i < connectsTo.length; i++) {
                string memory remoteConfigFile = string.concat("env/", connectsTo[i], ".json");
                string memory remoteConfig = vm.readFile(remoteConfigFile);

                connections[i] = AdapterConnections({
                    centrifugeId: uint16(_parseJsonUintOrDefault(remoteConfig, "$.network.centrifugeId")),
                    layerZeroId: uint32(_parseJsonUintOrDefault(remoteConfig, "$.adapters.layerZero.layerZeroEid")),
                    wormholeId: uint16(_parseJsonUintOrDefault(remoteConfig, "$.adapters.wormhole.wormholeId")),
                    axelarId: _parseJsonStringOrDefault(remoteConfig, "$.adapters.axelar.axelarId"),
                    chainlinkId: uint64(_parseJsonUintOrDefault(remoteConfig, "$.adapters.chainlink.chainSelector")),
                    threshold: uint8(_parseJsonUintOrDefault(remoteConfig, "$.adapters.threshold"))
                });
            }
        } catch {
            return new AdapterConnections[](0);
        }
    }
}

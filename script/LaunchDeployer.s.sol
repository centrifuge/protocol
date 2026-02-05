// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreInput, makeSalt} from "./CoreDeployer.s.sol";
import {UlnConfig, SetConfigParam} from "./utils/ILayerZeroEndpointV2Like.sol";
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

        address[] memory layerZeroDVNs = _parseAndValidateLayerZeroConfig(config);
        uint8 layerZeroBlockConfirmations = layerZeroDVNs.length > 0
            ? uint8(_parseJsonUintOrDefault(config, "$.adapters.layerZero.blockConfirmations"))
            : 0;

        address protocolAdmin = vm.parseJsonAddress(config, "$.network.protocolAdmin");

        FullInput memory input = FullInput({
            adminSafe: ISafe(protocolAdmin),
            opsSafe: ISafe(vm.parseJsonAddress(config, "$.network.opsAdmin")),
            core: CoreInput({
                centrifugeId: centrifugeId,
                version: version,
                root: vm.envOr("ROOT", address(0)),
                txLimits: _parseBatchLimits(config)
            }),
            adapters: AdaptersInput({
                layerZero: LayerZeroInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.layerZero.deploy"),
                    endpoint: _parseJsonAddressOrDefault(config, "$.adapters.layerZero.endpoint"),
                    delegate: protocolAdmin
                }),
                wormhole: WormholeInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.wormhole.deploy"),
                    relayer: _parseJsonAddressOrDefault(config, "$.adapters.wormhole.relayer")
                }),
                axelar: AxelarInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.axelar.deploy"),
                    gateway: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gateway"),
                    gasService: _parseJsonAddressOrDefault(config, "$.adapters.axelar.gasService")
                }),
                chainlink: ChainlinkInput({
                    shouldDeploy: _parseJsonBoolOrDefault(config, "$.adapters.chainlink.deploy"),
                    ccipRouter: _parseJsonAddressOrDefault(config, "$.adapters.chainlink.ccipRouter")
                }),
                connections: _buildConnections(_parseConnections(config), layerZeroDVNs, layerZeroBlockConfirmations)
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

    function _buildConnections(
        string[] memory connectsTo,
        address[] memory layerZeroDvns,
        uint8 layerZeroBlockConfirmations
    ) private view returns (AdapterConnections[] memory connections) {
        connections = new AdapterConnections[](connectsTo.length);

        for (uint256 i; i < connectsTo.length; i++) {
            string memory remoteConfigFile = string.concat("env/", connectsTo[i], ".json");
            string memory remoteConfig = vm.readFile(remoteConfigFile);

            _checkLayerZeroConfiguration(layerZeroDvns, layerZeroBlockConfirmations, remoteConfig);

            uint32 layerZeroId = _parseJsonBoolOrDefault(remoteConfig, "$.adapters.layerZero.deploy")
                ? uint32(_parseJsonUintOrDefault(remoteConfig, "$.adapters.layerZero.layerZeroEid"))
                : 0;

            connections[i] = AdapterConnections({
                centrifugeId: uint16(_parseJsonUintOrDefault(remoteConfig, "$.network.centrifugeId")),
                layerZeroId: layerZeroId,
                wormholeId: _parseJsonBoolOrDefault(remoteConfig, "$.adapters.wormhole.deploy")
                    ? uint16(_parseJsonUintOrDefault(remoteConfig, "$.adapters.wormhole.wormholeId"))
                    : 0,
                axelarId: _parseJsonBoolOrDefault(remoteConfig, "$.adapters.axelar.deploy")
                    ? _parseJsonStringOrDefault(remoteConfig, "$.adapters.axelar.axelarId")
                    : "",
                chainlinkId: _parseJsonBoolOrDefault(remoteConfig, "$.adapters.chainlink.deploy")
                    ? uint64(_parseJsonUintOrDefault(remoteConfig, "$.adapters.chainlink.chainSelector"))
                    : 0,
                threshold: uint8(_parseJsonUintOrDefault(remoteConfig, "$.adapters.threshold")),
                layerZeroConfigParams: _getLayerZeroConfigParams(
                        layerZeroId, layerZeroBlockConfirmations, layerZeroDvns
                    )
            });
        }
    }

    function _parseConnections(string memory config) internal pure returns (string[] memory connectsTo) {
        try vm.parseJsonStringArray(config, "$.network.connectsTo") returns (string[] memory connectsTo_) {
            return connectsTo_;
        } catch {
            return new string[](0);
        }
    }

    function _checkLayerZeroConfiguration(
        address[] memory layerZeroDvns,
        uint8 layerZeroBlockConfirmations,
        string memory remoteConfig
    ) private pure {
        if (layerZeroDvns.length == 0) return;

        uint8 remoteBlockConfirmations =
            uint8(_parseJsonUintOrDefault(remoteConfig, "$.adapters.layerZero.blockConfirmations"));
        require(
            remoteBlockConfirmations == layerZeroBlockConfirmations,
            "blockConfirmations mismatch between local and remote config"
        );
    }

    function _parseAndValidateLayerZeroConfig(string memory config) private pure returns (address[] memory) {
        try vm.parseJsonStringArray(config, "$.adapters.layerZero.DVNs") returns (string[] memory dvns) {
            address[] memory layerZeroDVNs = new address[](dvns.length);
            for (uint256 i; i < dvns.length; i++) {
                layerZeroDVNs[i] = vm.parseAddress(dvns[i]);
            }
            for (uint256 i = 1; i < layerZeroDVNs.length; i++) {
                require(layerZeroDVNs[i - 1] < layerZeroDVNs[i], "DVNs must be sorted in ascending order");
            }

            return layerZeroDVNs;
        } catch {
            return new address[](0);
        }
    }

    /// @notice Gets LayerZero SetConfigParam[] for a given connection
    /// @param layerZeroId The LayerZero endpoint id for the remote chain
    /// @param blockConfirmations block confirmations required
    /// @param dvns Required DVN addresses
    ///             Must be sorted alphabetically
    ///             Must be the same DVNs everywhere, though addresses can differ per chain
    function _getLayerZeroConfigParams(uint32 layerZeroId, uint8 blockConfirmations, address[] memory dvns)
        internal
        pure
        returns (SetConfigParam[] memory params)
    {
        if (dvns.length == 0) {
            return new SetConfigParam[](0);
        }

        uint32 ULN_CONFIG_TYPE = 2;

        /// @notice UlnConfig controls verification threshold for incoming messages
        /// @notice Receive config enforces these settings have been applied to the DVNs and Executor
        /// @dev 0 values will be interpreted as defaults, so to apply NIL settings, use:
        /// @dev uint8 internal constant NIL_DVN_COUNT = type(uint8).max;
        /// @dev uint64 internal constant NIL_CONFIRMATIONS = type(uint64).max;
        /// @dev confirmations must be the same on the source and destination chains
        UlnConfig memory uln = UlnConfig({
            confirmations: blockConfirmations,
            requiredDVNCount: uint8(dvns.length),
            optionalDVNCount: type(uint8).max,
            optionalDVNThreshold: 0,
            requiredDVNs: dvns,
            optionalDVNs: new address[](0)
        });

        params = new SetConfigParam[](1);
        params[0] = SetConfigParam(layerZeroId, ULN_CONFIG_TYPE, abi.encode(uln));
    }

    function _parseBatchLimits(string memory config) private view returns (uint8[32] memory batchLimits) {
        try vm.parseJsonStringArray(config, "$.network.connectsTo") returns (string[] memory connectsTo) {
            for (uint256 i; i < connectsTo.length; i++) {
                string memory remoteConfigFile = string.concat("env/", connectsTo[i], ".json");
                string memory remoteConfig = vm.readFile(remoteConfigFile);

                uint16 centrifugeId = _parseJsonUintOrDefault(remoteConfig, "$.network.centrifugeId").toUint16();
                if (centrifugeId <= 31) {
                    batchLimits[centrifugeId] = _parseJsonUintOrDefault(remoteConfig, "$.network.batchLimit").toUint8();
                } else {
                    revert("loaded centrifugeId value higher than 31");
                }
            }
        } catch {}
    }
}

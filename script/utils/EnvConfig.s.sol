// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnvConnections, Connection} from "./EnvConnectionsConfig.s.sol";

import "forge-std/Vm.sol";

import {AdapterConnections} from "../../src/deployment/ActionBatchers.sol";
import {UlnConfig, SetConfigParam} from "../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

library GraphQLConstants {
    string internal constant MAINNET_API = "https://api.centrifuge.io";
    string internal constant TESTNET_API = "https://api-v3-test.cfg.embrio.tech";
}

struct NetworkConfig {
    uint256 chainId;
    string environment;
    string name;
    uint16 centrifugeId;
    address protocolAdmin;
    address opsAdmin;
    uint8 batchLimit;
    string baseRpcUrl;
    string verifier;
    string verifierUrl;
}

struct LayerZeroConfig {
    address endpoint;
    uint32 layerZeroEid;
    bool deploy;
    uint8 blockConfirmations;
    address[] dvns;
}

struct WormholeConfig {
    uint16 wormholeId;
    address relayer;
    bool deploy;
}

struct AxelarConfig {
    string axelarId;
    address gateway;
    address gasService;
    bool deploy;
}

struct ChainlinkConfig {
    uint64 chainSelector;
    address ccipRouter;
    bool deploy;
}

struct AdaptersConfig {
    LayerZeroConfig layerZero;
    WormholeConfig wormhole;
    AxelarConfig axelar;
    ChainlinkConfig chainlink;
}

struct ContractsConfig {
    // Admin
    address root;
    address tokenRecoverer;
    address protocolGuardian;
    address opsGuardian;
    // Core
    address gasService;
    address gateway;
    address multiAdapter;
    address messageProcessor;
    address messageDispatcher;
    address poolEscrowFactory;
    address hubRegistry;
    address accounting;
    address holdings;
    address shareClassManager;
    address hub;
    address tokenFactory;
    address spoke;
    address balanceSheet;
    address contractUpdater;
    address vaultRegistry;
    address hubHandler;
    // Vaults
    address asyncRequestManager;
    address syncManager;
    address asyncVaultFactory;
    address syncDepositVaultFactory;
    address vaultRouter;
    address refundEscrowFactory;
    address subsidyManager;
    address queueManager;
    address batchRequestManager;
    // Hooks
    address freezeOnlyHook;
    address fullRestrictionsHook;
    address freelyTransferableHook;
    address redemptionRestrictionsHook;
    // Spoke managers
    address onOfframpManagerFactory;
    address merkleProofManagerFactory;
    address onOffRampFactory;
    // Valuations
    address identityValuation;
    address oracleValuation;
    // Hub managers
    address navManager;
    address simplePriceManager;
    // Decoders
    address vaultDecoder;
    address circleDecoder;
    // Adapters
    address layerZeroAdapter;
    address wormholeAdapter;
    address axelarAdapter;
    address chainlinkAdapter;
}

struct EnvConfig {
    NetworkConfig network;
    AdaptersConfig adapters;
    ContractsConfig contracts;
}

using NetworkConfigLib for NetworkConfig global;
using EnvConfigLib for EnvConfig global;

/// @notice loads an env/<network>.json file
library Env {
    function load(string memory network) internal view returns (EnvConfig memory config) {
        string memory json = vm.readFile(string.concat("env/", network, ".json"));

        config.network = _parseNetworkConfig(json);
        config.network.name = network;
        config.adapters = _parseAdaptersConfig(json);
        config.contracts = _parseContractsConfig(json);
    }

    function _parseNetworkConfig(string memory json) private pure returns (NetworkConfig memory config) {
        config.chainId = vm.parseJsonUint(json, ".network.chainId");
        config.environment = vm.parseJsonString(json, ".network.environment");
        config.centrifugeId = uint16(vm.parseJsonUint(json, ".network.centrifugeId"));
        config.protocolAdmin = vm.parseJsonAddress(json, ".network.protocolAdmin");
        config.opsAdmin = vm.parseJsonAddress(json, ".network.opsAdmin");
        config.baseRpcUrl = vm.parseJsonString(json, ".network.baseRpcUrl");

        try vm.parseJsonUint(json, ".network.batchLimit") returns (uint256 val) {
            config.batchLimit = uint8(val);
        } catch {}

        try vm.parseJsonString(json, ".network.verifier") returns (string memory val) {
            config.verifier = val;
        } catch {}

        try vm.parseJsonString(json, ".network.verifierUrl") returns (string memory val) {
            config.verifierUrl = val;
        } catch {
            config.verifierUrl = string.concat("https://api.etherscan.io/v2/api?chainid=", vm.toString(config.chainId));
        }
    }

    function _parseAdaptersConfig(string memory json) private pure returns (AdaptersConfig memory config) {
        try vm.parseJsonBool(json, ".adapters.layerZero.deploy") returns (bool val) {
            config.layerZero.deploy = val;
        } catch {}

        try vm.parseJsonBool(json, ".adapters.wormhole.deploy") returns (bool val) {
            config.wormhole.deploy = val;
        } catch {}

        try vm.parseJsonBool(json, ".adapters.axelar.deploy") returns (bool val) {
            config.axelar.deploy = val;
        } catch {}

        try vm.parseJsonBool(json, ".adapters.chainlink.deploy") returns (bool val) {
            config.chainlink.deploy = val;
        } catch {}

        if (config.layerZero.deploy) {
            config.layerZero.endpoint = vm.parseJsonAddress(json, ".adapters.layerZero.endpoint");
            config.layerZero.layerZeroEid = uint32(vm.parseJsonUint(json, ".adapters.layerZero.layerZeroEid"));
            config.layerZero.blockConfirmations =
                uint8(vm.parseJsonUint(json, ".adapters.layerZero.blockConfirmations"));
            config.layerZero.dvns = vm.parseJsonAddressArray(json, ".adapters.layerZero.DVNs");

            for (uint256 i = 1; i < config.layerZero.dvns.length; i++) {
                require(
                    config.layerZero.dvns[i - 1] < config.layerZero.dvns[i], "DVNs must be sorted in ascending order"
                );
            }
        }

        if (config.wormhole.deploy) {
            config.wormhole.wormholeId = uint16(vm.parseJsonUint(json, ".adapters.wormhole.wormholeId"));
            config.wormhole.relayer = vm.parseJsonAddress(json, ".adapters.wormhole.relayer");
        }

        if (config.axelar.deploy) {
            config.axelar.axelarId = vm.parseJsonString(json, ".adapters.axelar.axelarId");
            config.axelar.gateway = vm.parseJsonAddress(json, ".adapters.axelar.gateway");
            config.axelar.gasService = vm.parseJsonAddress(json, ".adapters.axelar.gasService");
        }

        if (config.chainlink.deploy) {
            config.chainlink.chainSelector = uint64(vm.parseJsonUint(json, ".adapters.chainlink.chainSelector"));
            config.chainlink.ccipRouter = vm.parseJsonAddress(json, ".adapters.chainlink.ccipRouter");
        }
    }

    function _parseContractsConfig(string memory json) private view returns (ContractsConfig memory config) {
        if (!vm.keyExistsJson(json, ".contracts")) {
            return config;
        }

        // Admin
        config.root = _parseContractAddress(json, "root");
        config.tokenRecoverer = _parseContractAddress(json, "tokenRecoverer");
        config.protocolGuardian = _parseContractAddress(json, "protocolGuardian");
        config.opsGuardian = _parseContractAddress(json, "opsGuardian");

        // Core
        config.gasService = _parseContractAddress(json, "gasService");
        config.gateway = _parseContractAddress(json, "gateway");
        config.multiAdapter = _parseContractAddress(json, "multiAdapter");
        config.messageProcessor = _parseContractAddress(json, "messageProcessor");
        config.messageDispatcher = _parseContractAddress(json, "messageDispatcher");
        config.poolEscrowFactory = _parseContractAddress(json, "poolEscrowFactory");
        config.hubRegistry = _parseContractAddress(json, "hubRegistry");
        config.accounting = _parseContractAddress(json, "accounting");
        config.holdings = _parseContractAddress(json, "holdings");
        config.shareClassManager = _parseContractAddress(json, "shareClassManager");
        config.hub = _parseContractAddress(json, "hub");
        config.tokenFactory = _parseContractAddress(json, "tokenFactory");
        config.spoke = _parseContractAddress(json, "spoke");
        config.balanceSheet = _parseContractAddress(json, "balanceSheet");
        config.contractUpdater = _parseContractAddress(json, "contractUpdater");
        config.vaultRegistry = _parseContractAddress(json, "vaultRegistry");
        config.hubHandler = _parseContractAddress(json, "hubHandler");

        // Vaults
        config.asyncRequestManager = _parseContractAddress(json, "asyncRequestManager");
        config.syncManager = _parseContractAddress(json, "syncManager");
        config.asyncVaultFactory = _parseContractAddress(json, "asyncVaultFactory");
        config.syncDepositVaultFactory = _parseContractAddress(json, "syncDepositVaultFactory");
        config.vaultRouter = _parseContractAddress(json, "vaultRouter");
        config.refundEscrowFactory = _parseContractAddress(json, "refundEscrowFactory");
        config.subsidyManager = _parseContractAddress(json, "subsidyManager");
        config.queueManager = _parseContractAddress(json, "queueManager");
        config.batchRequestManager = _parseContractAddress(json, "batchRequestManager");

        // Hooks
        config.freezeOnlyHook = _parseContractAddress(json, "freezeOnlyHook");
        config.fullRestrictionsHook = _parseContractAddress(json, "fullRestrictionsHook");
        config.freelyTransferableHook = _parseContractAddress(json, "freelyTransferableHook");
        config.redemptionRestrictionsHook = _parseContractAddress(json, "redemptionRestrictionsHook");

        // Spoke managers
        config.onOfframpManagerFactory = _parseContractAddress(json, "onOfframpManagerFactory");
        config.merkleProofManagerFactory = _parseContractAddress(json, "merkleProofManagerFactory");
        config.onOffRampFactory = _tryParseContractAddress(json, "onOffRampFactory");

        // Valuations
        config.identityValuation = _parseContractAddress(json, "identityValuation");
        config.oracleValuation = _parseContractAddress(json, "oracleValuation");

        // Hub managers
        config.navManager = _parseContractAddress(json, "navManager");
        config.simplePriceManager = _parseContractAddress(json, "simplePriceManager");

        // Decoders
        config.vaultDecoder = _parseContractAddress(json, "vaultDecoder");
        config.circleDecoder = _parseContractAddress(json, "circleDecoder");

        // Adapters
        config.layerZeroAdapter = _tryParseContractAddress(json, "layerZeroAdapter");
        config.wormholeAdapter = _tryParseContractAddress(json, "wormholeAdapter");
        config.axelarAdapter = _tryParseContractAddress(json, "axelarAdapter");
        config.chainlinkAdapter = _tryParseContractAddress(json, "chainlinkAdapter");
    }

    function _parseContractAddress(string memory json, string memory key) private pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(".contracts.", key, ".address"));
    }

    function _tryParseContractAddress(string memory json, string memory key) private pure returns (address) {
        try vm.parseJsonAddress(json, string.concat(".contracts.", key, ".address")) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }
}

library EnvConfigLib {
    function etherscanApiKey(EnvConfig memory) internal view returns (string memory) {
        return prettyEnvString("ETHERSCAN_API_KEY");
    }

    function buildLayerZeroConfigParams(EnvConfig memory config)
        internal
        view
        returns (SetConfigParam[] memory params)
    {
        if (!config.adapters.layerZero.deploy) return params;

        Connection[] memory connections = config.network.connections();

        // Count LZ-enabled connections
        uint256 count;
        for (uint256 i; i < connections.length; i++) {
            if (connections[i].layerZero) count++;
        }

        params = new SetConfigParam[](count);

        // UlnConfig is the same for all connections - only eid differs
        uint32 ULN_CONFIG_TYPE = 2;
        bytes memory encodedUln = abi.encode(
            UlnConfig({
                confirmations: config.adapters.layerZero.blockConfirmations,
                requiredDVNCount: uint8(config.adapters.layerZero.dvns.length),
                optionalDVNCount: type(uint8).max,
                optionalDVNThreshold: 0,
                requiredDVNs: config.adapters.layerZero.dvns,
                optionalDVNs: new address[](0)
            })
        );

        uint256 idx;
        for (uint256 i; i < connections.length; i++) {
            if (!connections[i].layerZero) continue;

            EnvConfig memory remoteConfig = Env.load(connections[i].network);

            require(
                config.adapters.layerZero.dvns.length == remoteConfig.adapters.layerZero.dvns.length,
                "DVNs count mismatch between local and remote config"
            );
            require(
                config.adapters.layerZero.blockConfirmations == remoteConfig.adapters.layerZero.blockConfirmations,
                "blockConfirmations mismatch between local and remote config"
            );

            params[idx++] = SetConfigParam(remoteConfig.adapters.layerZero.layerZeroEid, ULN_CONFIG_TYPE, encodedUln);
        }
    }

    function adapterConnections(EnvConfig memory config)
        internal
        view
        returns (AdapterConnections[] memory adapterConnections_)
    {
        Connection[] memory connections = config.network.connections();
        adapterConnections_ = new AdapterConnections[](connections.length);

        for (uint256 i; i < connections.length; i++) {
            EnvConfig memory remoteConfig = Env.load(connections[i].network);
            Connection memory connection = connections[i];

            adapterConnections_[i] = AdapterConnections({
                centrifugeId: remoteConfig.network.centrifugeId,
                layerZeroId: connection.layerZero ? remoteConfig.adapters.layerZero.layerZeroEid : 0,
                wormholeId: connection.wormhole ? remoteConfig.adapters.wormhole.wormholeId : 0,
                axelarId: connection.axelar ? remoteConfig.adapters.axelar.axelarId : "",
                chainlinkId: connection.chainlink ? remoteConfig.adapters.chainlink.chainSelector : 0,
                threshold: connection.threshold
            });
        }
    }
}

library NetworkConfigLib {
    function buildBatchLimits(NetworkConfig memory config) internal view returns (uint8[32] memory batchLimits) {
        Connection[] memory connections_ = config.connections();
        for (uint256 i; i < connections_.length; i++) {
            EnvConfig memory remoteConfig = Env.load(connections_[i].network);

            uint16 centrifugeId = remoteConfig.network.centrifugeId;
            require(centrifugeId <= 31, "centrifugeId value higher than 31");

            batchLimits[centrifugeId] = remoteConfig.network.batchLimit;
        }
    }

    function connections(NetworkConfig memory config) internal view returns (Connection[] memory) {
        return EnvConnections.load(config.environment).connectionsWith(config.name);
    }

    function rpcUrl(NetworkConfig memory config) internal view returns (string memory) {
        string memory apiKey = "";
        if (_contains(config.baseRpcUrl, "alchemy")) apiKey = prettyEnvString("ALCHEMY_API_KEY");
        else if (_contains(config.baseRpcUrl, "plume")) apiKey = prettyEnvString("PLUME_API_KEY");
        else if (_contains(config.baseRpcUrl, "pharos")) apiKey = prettyEnvString("PHAROS_API_KEY");

        return string.concat(config.baseRpcUrl, apiKey);
    }

    function isMainnet(NetworkConfig memory config) internal pure returns (bool) {
        return keccak256(bytes(config.environment)) == keccak256("mainnet");
    }

    function graphQLApi(NetworkConfig memory config) internal pure returns (string memory) {
        return config.isMainnet() ? GraphQLConstants.MAINNET_API : GraphQLConstants.TESTNET_API;
    }

    function _contains(string memory str, string memory substr) private pure returns (bool) {
        return _indexOf(str, substr) != type(uint256).max;
    }

    function _indexOf(string memory str, string memory substr) private pure returns (uint256) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);

        if (substrBytes.length > strBytes.length) return type(uint256).max;

        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }
}

function prettyEnvString(string memory name) view returns (string memory value) {
    value = vm.envOr(name, string(""));
    if (bytes(value).length == 0) revert(string.concat("Missing env var: ", name));
}

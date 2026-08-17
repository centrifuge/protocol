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
    // `.network.baseRpcUrl` is deliberately not here: the RPC URL a script connects with comes from
    // foundry.toml's [rpc_endpoints], which check_foundry_networks.py derives from that field. Parsing it
    // again would be a second way to build the same URL, and the two would drift
    //
    // Two explorer URLs, because they are two different services. `verifierUrl` is where source is SUBMITTED
    // for verification — for the Blockscout-family explorers that is a write-only endpoint that rejects
    // every read. `explorerApiUrl` is where chain data is READ back, which is what VerifyFactoryContracts
    // asks when checking whether a contract is verified already. They coincide on Etherscan, and on
    // Blockscout instances exposing an Etherscan-compatible /api, which is why one field served both for so
    // long; they diverge on SocialScan, whose verification endpoint answers "the action is error" to reads
    string verifier;
    string verifierUrl;
    string explorerApiUrl;
}

struct LayerZeroConfig {
    address endpoint;
    uint32 layerZeroEid;
    bool deploy;
    uint8 blockConfirmations;
    address[] requiredDVNs;
    address[] optionalDVNs;
    uint8 optionalDVNThreshold;
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

struct HyperlaneConfig {
    uint32 hyperlaneId;
    address mailbox;
    address ism;
    bool deploy;
}

struct AdaptersConfig {
    LayerZeroConfig layerZero;
    AxelarConfig axelar;
    ChainlinkConfig chainlink;
    HyperlaneConfig hyperlane;
}

struct ContractsConfig {
    // Admin
    address root;
    address protocolGuardian;
    address opsGuardian;
    address gasService;
    // Core
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
    address shareTokenRegistrar;
    address spoke;
    address spokeHandler;
    address spokeRegistry;
    address snapshotQueue;
    address balanceSheet;
    address contractUpdater;
    address envoy;
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
    address shareManager;
    // Valuations
    address identityValuation;
    address oracleValuation;
    // Hub managers
    address navManager;
    address simplePriceManager;
    // Bridge
    address tokenBridge;
    // Bridge hooks
    address bridgeCircuitBreaker;
    // Decoders
    address vaultDecoder;
    address circleDecoder;
    // Deployment
    address deployGate;
    // Adapters
    address layerZeroAdapter;
    address axelarAdapter;
    address chainlinkAdapter;
    address hyperlaneAdapter;
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
    /// @dev What `vm.indexOf` answers when the key is not in the string
    uint256 private constant NOT_FOUND = type(uint256).max;

    /// @notice Loads the config of the chain the run is pointed at, resolved by chain id: every network
    ///         config names its chainId and they are unique, so `--rpc-url <network>` is the only input a
    ///         script needs, and the one that decides both where it connects and what it reads.
    function load() internal view returns (EnvConfig memory config) {
        return load(detect());
    }

    function load(string memory network) internal view returns (EnvConfig memory config) {
        string memory json = vm.readFile(string.concat("env/", network, ".json"));

        config.network = _parseNetworkConfig(json);
        config.network.name = network;
        config.adapters = _parseAdaptersConfig(json);
        config.contracts = _parseContractsConfig(json);
    }

    /// @notice The network name `block.chainid` belongs to. Walks env/ two levels deep, so the configs an
    ///         anvil run copies under env/anvil/ are found on their fork's own chain id, and skips anything
    ///         that is not a network config (the connections files, the archived spells).
    ///
    /// @dev    There is deliberately no override: the chain the RPC points at is the single source of truth,
    ///         so a script cannot be pointed at one chain while reading another's addresses. A script that
    ///         has to choose a network *before* it has a chain — one that reads a config to know where to
    ///         fork, as VerifyFactoryContracts does — passes the name to `load(name)` instead.
    function detect() internal view returns (string memory) {
        // readDir answers with absolute paths; everything below reasons relative to the project root
        string memory root = string.concat(vm.projectRoot(), "/");

        Vm.DirEntry[] memory entries = vm.readDir("env", 2);
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].isDir) continue;

            string memory path = vm.replace(entries[i].path, root, "");
            if (!_isJson(path)) continue;

            string memory json = vm.readFile(entries[i].path);
            if (!vm.keyExistsJson(json, ".network.chainId")) continue;
            if (vm.parseJsonUint(json, ".network.chainId") != block.chainid) continue;

            // env/<name>.json, where <name> may contain a directory (anvil/sepolia)
            return vm.replace(vm.replace(path, "env/", ""), ".json", "");
        }

        revert(
            string.concat(
                "No env config for chain ",
                vm.toString(block.chainid),
                ": add env/<network>.json naming that chainId, and point --rpc-url at it"
            )
        );
    }

    /// @dev The only filter the walk needs, and it is not optional: `keyExistsJson` *reverts* on anything
    ///      that is not JSON, so the spells under env/spell/ would end the walk rather than be skipped by it.
    ///      Everything else that parses — a connections file — has no `.network.chainId` and falls out below.
    ///      Anchored to the end, so a `.json.bak` left lying around is not read as a config.
    function _isJson(string memory path) private pure returns (bool) {
        uint256 at = vm.indexOf(path, ".json");
        return at != NOT_FOUND && at == bytes(path).length - 5;
    }

    function _parseNetworkConfig(string memory json) private pure returns (NetworkConfig memory config) {
        config.chainId = vm.parseJsonUint(json, ".network.chainId");
        config.environment = vm.parseJsonString(json, ".network.environment");
        config.centrifugeId = uint16(vm.parseJsonUint(json, ".network.centrifugeId"));
        config.protocolAdmin = vm.parseJsonAddress(json, ".network.protocolAdmin");
        config.opsAdmin = vm.parseJsonAddress(json, ".network.opsAdmin");

        try vm.parseJsonUint(json, ".network.batchLimit") returns (uint256 val) {
            config.batchLimit = uint8(val);
        } catch {}

        try vm.parseJsonString(json, ".network.verifier") returns (string memory val) {
            config.verifier = val;
        } catch {}

        // Etherscan's multichain v2 endpoint covers most chains by id, and is where both submission and
        // reads go unless a network names something else
        string memory etherscanV2 =
            string.concat("https://api.etherscan.io/v2/api?chainid=", vm.toString(config.chainId));

        try vm.parseJsonString(json, ".network.verifierUrl") returns (string memory val) {
            config.verifierUrl = val;
        } catch {
            config.verifierUrl = etherscanV2;
        }

        // Only read for explorers speaking the Etherscan dialect: a network verifying through Sourcify asks
        // Sourcify whether a contract is verified, so this default is never reached for one.
        //
        // Only set where the explorer's read API is somewhere other than where verification is submitted.
        // Falling back to Etherscan v2 rather than to `verifierUrl` is the point of keeping them apart: a
        // network that names a write-only verification endpoint gets a working read URL by default, and one
        // whose reads genuinely live elsewhere says so explicitly
        try vm.parseJsonString(json, ".network.explorerApiUrl") returns (string memory val) {
            config.explorerApiUrl = val;
        } catch {
            config.explorerApiUrl = etherscanV2;
        }
    }

    function _parseAdaptersConfig(string memory json) private pure returns (AdaptersConfig memory config) {
        try vm.parseJsonBool(json, ".adapters.layerZero.deploy") returns (bool val) {
            config.layerZero.deploy = val;
        } catch {}

        try vm.parseJsonBool(json, ".adapters.axelar.deploy") returns (bool val) {
            config.axelar.deploy = val;
        } catch {}

        try vm.parseJsonBool(json, ".adapters.chainlink.deploy") returns (bool val) {
            config.chainlink.deploy = val;
        } catch {}

        try vm.parseJsonBool(json, ".adapters.hyperlane.deploy") returns (bool val) {
            config.hyperlane.deploy = val;
        } catch {}

        if (config.layerZero.deploy) {
            config.layerZero.endpoint = vm.parseJsonAddress(json, ".adapters.layerZero.endpoint");
            config.layerZero.layerZeroEid = uint32(vm.parseJsonUint(json, ".adapters.layerZero.layerZeroEid"));
            config.layerZero.blockConfirmations =
                uint8(vm.parseJsonUint(json, ".adapters.layerZero.blockConfirmations"));
            config.layerZero.requiredDVNs = vm.parseJsonAddressArray(json, ".adapters.layerZero.requiredDVNs");
            config.layerZero.optionalDVNs = vm.parseJsonAddressArray(json, ".adapters.layerZero.optionalDVNs");
            config.layerZero.optionalDVNThreshold =
                uint8(vm.parseJsonUint(json, ".adapters.layerZero.optionalDVNThreshold"));

            // Bound list lengths to the uint8 cap LayerZero stores them in. Without this, a 256+
            // entry list would silently truncate via `uint8(...length)` in `encodeUlnConfig`,
            // collapsing optional DVNs to NIL or undercounting required DVNs
            require(config.layerZero.requiredDVNs.length <= 255, "too many requiredDVNs (uint8 cap)");
            require(config.layerZero.optionalDVNs.length <= 255, "too many optionalDVNs (uint8 cap)");

            // Enforce the ascending-sort invariant LayerZero UlnBase expects, for each list independently.
            for (uint256 i = 1; i < config.layerZero.requiredDVNs.length; i++) {
                require(
                    config.layerZero.requiredDVNs[i - 1] < config.layerZero.requiredDVNs[i],
                    "requiredDVNs must be sorted in ascending order"
                );
            }
            for (uint256 i = 1; i < config.layerZero.optionalDVNs.length; i++) {
                require(
                    config.layerZero.optionalDVNs[i - 1] < config.layerZero.optionalDVNs[i],
                    "optionalDVNs must be sorted in ascending order"
                );
            }
            // Disjoint check: LayerZero's UlnBase allows overlap between required and optional lists,
            // but a DVN appearing in both collapses our "distinct operators to forge" guarantee — it
            // would be counted as both a required attestation and a slot of the optional threshold
            for (uint256 i; i < config.layerZero.requiredDVNs.length; i++) {
                for (uint256 j; j < config.layerZero.optionalDVNs.length; j++) {
                    require(
                        config.layerZero.requiredDVNs[i] != config.layerZero.optionalDVNs[j],
                        "DVN appears in both required and optional lists"
                    );
                }
            }
            // Mirror UlnBase.LZ_ULN_InvalidOptionalDVNThreshold: 0 < threshold <= optionalDVNs.length
            // (when optionalDVNs is empty, threshold must be 0).
            if (config.layerZero.optionalDVNs.length == 0) {
                require(
                    config.layerZero.optionalDVNThreshold == 0, "optionalDVNThreshold must be 0 when no optional DVNs"
                );
            } else {
                require(
                    config.layerZero.optionalDVNThreshold > 0
                        && config.layerZero.optionalDVNThreshold <= config.layerZero.optionalDVNs.length,
                    "optionalDVNThreshold must be in (0, optionalDVNs.length]"
                );
            }
            // Mirror UlnBase.LZ_ULN_AtLeastOneDVN: at least one required DVN or a non-zero optional threshold.
            require(
                config.layerZero.requiredDVNs.length > 0 || config.layerZero.optionalDVNThreshold > 0,
                "Must have at least one required DVN or a non-zero optional threshold"
            );
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

        if (config.hyperlane.deploy) {
            config.hyperlane.hyperlaneId = uint32(vm.parseJsonUint(json, ".adapters.hyperlane.hyperlaneId"));
            config.hyperlane.mailbox = vm.parseJsonAddress(json, ".adapters.hyperlane.mailbox");
            // ISM is optional: a deployment may leave it unset (falls back to the Mailbox default ISM).
            try vm.parseJsonAddress(json, ".adapters.hyperlane.ism") returns (address val) {
                config.hyperlane.ism = val;
            } catch {}
        }
    }

    function _parseContractsConfig(string memory json) private view returns (ContractsConfig memory config) {
        if (!vm.keyExistsJson(json, ".contracts")) {
            return config;
        }

        // Admin
        config.root = _parseContractAddress(json, "root");
        config.protocolGuardian = _parseContractAddress(json, "protocolGuardian");
        config.opsGuardian = _parseContractAddress(json, "opsGuardian");
        config.gasService = _parseContractAddress(json, "gasService");

        // Core
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
        config.shareTokenRegistrar = _tryParseContractAddress(json, "shareTokenRegistrar");
        config.spoke = _parseContractAddress(json, "spoke");
        config.spokeHandler = _tryParseContractAddress(json, "spokeHandler");
        config.spokeRegistry = _tryParseContractAddress(json, "spokeRegistry");
        config.snapshotQueue = _tryParseContractAddress(json, "snapshotQueue");
        config.balanceSheet = _parseContractAddress(json, "balanceSheet");
        config.contractUpdater = _tryParseContractAddress(json, "contractUpdater");
        config.envoy = _tryParseContractAddress(json, "envoy");
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

        // Spoke managers. The onOfframp/merkleProof factories are legacy: chains deployed after
        // OnOffRamp and OnchainPM superseded them only carry onOffRampFactory.
        config.onOfframpManagerFactory = _tryParseContractAddress(json, "onOfframpManagerFactory");
        config.merkleProofManagerFactory = _tryParseContractAddress(json, "merkleProofManagerFactory");
        config.onOffRampFactory = _tryParseContractAddress(json, "onOffRampFactory");
        config.shareManager = _tryParseContractAddress(json, "shareManager");

        // Valuations
        config.identityValuation = _parseContractAddress(json, "identityValuation");
        config.oracleValuation = _parseContractAddress(json, "oracleValuation");

        // Hub managers
        config.navManager = _parseContractAddress(json, "navManager");
        config.simplePriceManager = _parseContractAddress(json, "simplePriceManager");
        config.bridgeCircuitBreaker = _tryParseContractAddress(json, "bridgeCircuitBreaker");

        // Bridge
        config.tokenBridge = _tryParseContractAddress(json, "tokenBridge");

        // Deployment: written by DeployGateDeployer, absent on chains deployed before it existed
        config.deployGate = _tryParseContractAddress(json, "deployGate");

        // Decoders. Legacy companions of merkleProofManagerFactory: absent on newer chains.
        config.vaultDecoder = _tryParseContractAddress(json, "vaultDecoder");
        config.circleDecoder = _tryParseContractAddress(json, "circleDecoder");

        // Adapters
        config.layerZeroAdapter = _tryParseContractAddress(json, "layerZeroAdapter");
        config.axelarAdapter = _tryParseContractAddress(json, "axelarAdapter");
        config.chainlinkAdapter = _tryParseContractAddress(json, "chainlinkAdapter");
        config.hyperlaneAdapter = _tryParseContractAddress(json, "hyperlaneAdapter");
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
    /// @dev LayerZero `UlnBase.NIL_DVN_COUNT` sentinel: explicitly opts out of optional DVNs
    ///      (vs `0` which means "inherit the endpoint default optional DVN set")
    uint8 internal constant NIL_DVN_COUNT = type(uint8).max;

    /// @dev LayerZero `MessageLib` config type for `UlnConfig`.
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    function etherscanApiKey(EnvConfig memory) internal view returns (string memory) {
        return prettyEnvString("ETHERSCAN_API_KEY");
    }

    /// @dev Encode the `UlnConfig` for a given LayerZero adapter config. Encodes `optionalDVNCount`
    ///      as `NIL_DVN_COUNT` when the optional set is empty so the OApp explicitly opts out of
    ///      inheriting endpoint-level default optional DVNs.
    function encodeUlnConfig(LayerZeroConfig memory lz) internal pure returns (bytes memory) {
        uint8 optionalCount = uint8(lz.optionalDVNs.length);
        return abi.encode(
            UlnConfig({
                confirmations: lz.blockConfirmations,
                requiredDVNCount: uint8(lz.requiredDVNs.length),
                optionalDVNCount: optionalCount == 0 ? NIL_DVN_COUNT : optionalCount,
                optionalDVNThreshold: lz.optionalDVNThreshold,
                requiredDVNs: lz.requiredDVNs,
                optionalDVNs: lz.optionalDVNs
            })
        );
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

        // UlnConfig is the same for all connections - only eid differs.
        bytes memory encodedUln = encodeUlnConfig(config.adapters.layerZero);

        uint256 idx;
        for (uint256 i; i < connections.length; i++) {
            if (!connections[i].layerZero) continue;

            EnvConfig memory remoteConfig = Env.load(connections[i].network);

            require(
                config.adapters.layerZero.blockConfirmations == remoteConfig.adapters.layerZero.blockConfirmations,
                "blockConfirmations mismatch between local and remote config"
            );
            // Enforce uniform DVN security shape across the bidirectional connection. DVN addresses
            // legitimately differ per chain.
            // NOTE: The shape (required count, optional count, threshold) must match such that each side
            // counts the same number of attestations.
            require(
                config.adapters.layerZero.requiredDVNs.length == remoteConfig.adapters.layerZero.requiredDVNs.length
                    && config.adapters.layerZero.optionalDVNs.length
                        == remoteConfig.adapters.layerZero.optionalDVNs.length
                    && config.adapters.layerZero.optionalDVNThreshold
                        == remoteConfig.adapters.layerZero.optionalDVNThreshold,
                "DVN config shape mismatch between local and remote"
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
                axelarId: connection.axelar ? remoteConfig.adapters.axelar.axelarId : "",
                chainlinkId: connection.chainlink ? remoteConfig.adapters.chainlink.chainSelector : 0,
                hyperlaneId: connection.hyperlane ? remoteConfig.adapters.hyperlane.hyperlaneId : 0,
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

    /// @dev Resolves the `[rpc_endpoints]` alias named after the network, which is where a base URL and its
    ///      API key are composed. Keeping that in foundry.toml is what lets `--rpc-url <network>` on the
    ///      command line and this function reach the same endpoint.
    function rpcUrl(NetworkConfig memory config) internal view returns (string memory) {
        return vm.rpcUrl(config.name);
    }

    function isMainnet(NetworkConfig memory config) internal pure returns (bool) {
        return keccak256(bytes(config.environment)) == keccak256("mainnet");
    }

    function graphQLApi(NetworkConfig memory config) internal pure returns (string memory) {
        return config.isMainnet() ? GraphQLConstants.MAINNET_API : GraphQLConstants.TESTNET_API;
    }
}

function prettyEnvString(string memory name) view returns (string memory value) {
    value = vm.envOr(name, string(""));
    if (bytes(value).length == 0) revert(string.concat("Missing env var: ", name));
}

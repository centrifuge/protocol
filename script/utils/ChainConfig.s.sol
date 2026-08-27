// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnvConnections, Connection} from "./ConnectionsConfig.s.sol";

import "forge-std/Vm.sol";

import {AdapterConnections} from "../../src/deployment/ActionBatchers.sol";
import {UlnConfig, SetConfigParam} from "../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

// Deploy-time types, here because their builders are: `adapterConnections()` and
// `buildLayerZeroConfigParams()` each have exactly one caller, `LaunchDeployer`, which stays on the base
// branch — so these belong here, not on `live`

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev No caller on the base branch: the live branch's `VerifyFactoryContracts` and spell validators are
///      the consumers. Kept here for the same reason `configRoots()` lists environments this branch does
///      not populate — the schema of what a config offers belongs with the schema, not with whoever
///      happens to read it. The same holds for `etherscanApiKey`, `rpcUrl`, `graphQLApi` and
///      `prettyEnvString` below: zero base-branch callers, deleting any of them breaks the live branch.
library GraphQLConstants {
    string internal constant MAINNET_API = "https://api.centrifuge.io";
    string internal constant TESTNET_API = "https://api-v3-test.cfg.embrio.tech";
}

struct NetworkConfig {
    uint256 chainId;
    // The directory this config sits in, restated: `testnet`, or `testnet-rev2` for a second deployment of
    // the same chains beside the first. `deploymentId` below is the part after the first `-`, and
    // `baseEnvironment()` the part before it — the two are derived from this one string, never stated apart
    string environment;
    string name;
    uint16 centrifugeId;
    address protocolAdmin;
    address opsAdmin;
    // Account whose namespace in the DeployGate the deployment lives in, which every address on this chain
    // derives from alongside the salt. Mandatory: it can never be replaced, and a run that guessed it
    // wrong would deploy a whole protocol at addresses nobody meant. It is not the protocol admin — the
    // two answer different questions, and a chain is free to point them at different accounts
    address namespace;
    // Which deployment this is, among the several one namespace could put on this chain. Derived from
    // `environment`, never parsed: empty for the canonical one, and folded into every version otherwise, so
    // two deployments under two ids occupy two disjoint sets of addresses. Mainnet is no exception — the
    // canonical deployment there is the id-less one, but nothing here keeps a rev off it
    string deploymentId;
    uint8 batchLimit;
    // `.network.baseRpcUrl` is deliberately not here: the RPC URL a script connects with comes from
    // foundry.toml's [rpc_endpoints], which check_foundry_networks.py derives from that field, alongside the
    // configs. Parsing it again would be a second way to build the same URL, and the two would drift
    //
    // Two explorer URLs, because they are two different services. `verifierUrl` is where source is SUBMITTED
    // for verification — for the Blockscout-family explorers that is a write-only endpoint that rejects
    // every read. `explorerApiUrl` is where chain data is READ back, which is what the verification flow
    // asks when checking whether a contract is verified already. They coincide on Etherscan, and on
    // Blockscout instances exposing an Etherscan-compatible /api, which is why one field served both for so
    // long; they diverge on explorers whose verification endpoint rejects every read
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

/// @notice What a chain *is*, as `env/<environment>/<network>.json` describes it: the chain itself and the messaging
///         it takes part in. Nothing here assumes the protocol is deployed on it, which is why a script
///         that brings a chain up from nothing (`LaunchDeployer`) reads this and not `EnvConfig`.
struct ChainConfig {
    NetworkConfig network;
    AdaptersConfig adapters;
}

using NetworkConfigLib for NetworkConfig global;
using ChainConfigLib for ChainConfig global;

/// @notice Loads the structural half of an env/<environment>/<network>.json
library Chains {
    /// @notice Every directory a config can sit in, in the order they are searched.
    ///
    /// @dev    One per `.network.environment`, plus the fixtures describing the local chains
    ///         `script/anvil/anvil.sh` brings up — those are checked in beside the script that uses them
    ///         and copied into `env/anvil-<id>/` for a run, so both places hold configs and the copy wins.
    ///         Which base names a directory may carry is `environments()`.
    function configRoots() internal view returns (string[] memory roots) {
        Vm.DirEntry[] memory entries = entriesOf("env/");

        uint256 found;
        string[] memory all = new string[](entries.length + 1);
        for (uint256 i; i < entries.length; i++) {
            if (!entries[i].isDir) continue;

            string memory dir = vm.replace(entries[i].path, string.concat(vm.projectRoot(), "/"), "");
            // `env/spell/` is the executed-spell archive, not an environment
            if (!isEnvironment(baseEnvironmentOf(_basename(dir)))) continue;

            all[found++] = string.concat(dir, "/");
        }

        all[found++] = FIXTURE_ROOT;

        roots = new string[](found);
        for (uint256 i; i < found; i++) {
            roots[i] = all[i];
        }
    }

    /// @notice The environments a directory under `env/` may be named after, before its deployment id.
    ///
    /// @dev    `mainnet` and `testnet` are populated only on the `live` branch: those deployments are made
    ///         from there, and their configs live with them. They are listed here regardless, because what
    ///         a config *is* belongs to the schema and which directories carry one is the branch's
    ///         business. Validating against the list is what keeps a typo — `env/tesnet-rev2/` — from
    ///         quietly becoming an environment of its own: `configRoots()` leaves such a directory out, and
    ///         `ChainConfigDirectoryTest` is what turns one that is checked in into a failure.
    function environments() internal pure returns (string[] memory names) {
        names = new string[](3);
        names[0] = "mainnet";
        names[1] = "testnet";
        names[2] = FIXTURE_ENVIRONMENT;
    }

    /// @notice Whether a base environment is one `environments()` lists
    function isEnvironment(string memory base) internal pure returns (bool) {
        string[] memory names = environments();
        for (uint256 i; i < names.length; i++) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(base))) return true;
        }
        return false;
    }

    function _slice(string memory value, uint256 from, uint256 to) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        bytes memory out = new bytes(to - from);
        for (uint256 i; i < out.length; i++) {
            out[i] = raw[from + i];
        }
        return string(out);
    }

    /// @dev Last path segment, the directory's own name
    function _basename(string memory path) private pure returns (string memory) {
        string[] memory parts = vm.split(path, "/");
        return parts[parts.length - 1];
    }

    /// @dev What `vm.indexOf` answers when the key is not in the string
    uint256 private constant NOT_FOUND = type(uint256).max;

    /// @dev The local chains' fixtures, the one config root that is not an environment directory: they are
    ///      the template `anvil.sh` copies into `env/anvil-<id>/` for a run, so they are read when no run
    ///      has copied them yet and shadowed by the copy when one has
    string internal constant FIXTURE_ROOT = "script/anvil/env/";

    /// @dev The environment the fixtures declare, and the base of the one a local run's copies declare
    string internal constant FIXTURE_ENVIRONMENT = "anvil";

    /// @notice Loads the config of the chain the run is pointed at, resolved by chain id: every network
    ///         config names its chainId and they are unique, so `--rpc-url <network>` is the only input a
    ///         script needs, and the one that decides both where it connects and what it reads.
    function load() internal view returns (ChainConfig memory config) {
        return load(detect());
    }

    /// @notice The raw JSON of a network's config, for `Env` to parse both halves out of one read of its
    ///         own. (`pathOf` probes by reading, so the winning file is read twice end to end — measured at
    ///         well under a percent of the gas limit across a full deployer walk, and left that way.)
    function jsonOf(string memory network) internal view returns (string memory) {
        string memory path = pathOf(network);
        string memory json = vm.readFile(path);

        _assertDirectoryRestatesTheEnvironment(path, json);

        return json;
    }

    /// @dev A config's `.network.environment` names the directory it sits in, deployment id and all, so the
    ///      two can be checked against each other on every read — which is the whole point of stating it
    ///      twice. Renaming a directory without editing the field, or copying a rev without editing it,
    ///      would otherwise move every address the chain deploys to and say nothing. The fixtures are
    ///      exempt: they are a template, not a deployment, and live outside `env/` for that reason.
    function _assertDirectoryRestatesTheEnvironment(string memory path, string memory json) private pure {
        if (vm.indexOf(path, FIXTURE_ROOT) == 0) return;

        string memory environment = vm.parseJsonString(json, ".network.environment");
        string memory expected = string.concat("env/", environment, "/");

        require(
            vm.indexOf(path, expected) == 0,
            string.concat("Config at ", path, " says it belongs to environment ", environment)
        );
    }

    /// @notice Where a network's config lives, which is `env/<environment>/<network>.json` — the directory
    ///         restates what the config's own `.network.environment` says, so that a glob can pick out one
    ///         environment without opening every file.
    ///
    /// @dev    Resolved by looking rather than by rule, because the name is all a caller has and the
    ///         environment is inside the file it is trying to find. Every root `configRoots()` names is
    ///         probed — there is no flat `env/<network>.json` form left: `detect()` and the directory walks
    ///         all strip the root, so a name never carries a directory.
    function pathOf(string memory network) internal view returns (string memory) {
        // The name is the primary key a run is addressed by, so it may resolve to exactly one config: the
        // first hit is only taken after the remaining roots are checked, because a name present in two
        // environments would otherwise silently answer with the wrong chain's admins and addresses —
        // `detect()` warns that exact mistake does not fail. The one sanctioned shadow is a local run's
        // copy in env/anvil-<id>/ over the fixture it was copied from, which are two files describing one chain.
        string memory found;
        string memory scope = _scope();
        string[] memory roots = configRoots();
        for (uint256 i; i < roots.length; i++) {
            if (!inScope(roots[i], scope)) continue;

            string memory nested = string.concat(roots[i], network, ".json");
            if (!_readable(nested)) continue;

            if (bytes(found).length == 0) {
                found = nested;
            } else if (_isFixtureShadow(found, nested)) {
                // The run's own copy answers, never the template it came from, whichever was seen first
                if (vm.indexOf(found, FIXTURE_ROOT) == 0) found = nested;
            } else {
                revert(string.concat("Ambiguous network name ", network, ": ", found, " and ", nested));
            }
        }
        if (bytes(found).length != 0) return found;

        revert(string.concat("No env config named ", network, ": expected env/<environment>/", network, ".json"));
    }

    /// @dev The environment a run is confined to, or nothing. `DEPLOY_ENVIRONMENT` is what a run says when a
    ///      chain is described more than once — `env/testnet/` beside `env/testnet-rev2/` — and needs to
    ///      name which of the two it means. Unset until that happens. It settles that one question and no
    ///      other: the directories of *other* base environments stay readable, so `DEPLOY_ENVIRONMENT=
    ///      testnet-rev2` hides `env/testnet/` and leaves `env/mainnet/` where it was. Read and checked once
    ///      per walk, not once per root.
    ///
    ///      A value naming no directory under `env/` is refused rather than left to filter every root out —
    ///      the run would otherwise fail on "no config for this chain" with the cause sitting in the
    ///      environment. (Named `DEPLOY_ENVIRONMENT` and not `ENVIRONMENT` for the same reason: the shorter
    ///      one is what shells and CI runners export for their own purposes, and it would trip this.)
    function _scope() private view returns (string memory) {
        string memory only = vm.envOr("DEPLOY_ENVIRONMENT", string(""));
        if (bytes(only).length == 0) return "";

        require(
            isEnvironment(baseEnvironmentOf(only)) && entriesOf(string.concat("env/", only, "/")).length > 0,
            string.concat("DEPLOY_ENVIRONMENT=", only, " names no directory under env/: unset it, or point it at one")
        );
        return only;
    }

    /// @notice Whether a root is in the scope `_scope()` answered: every root of another base environment, and
    ///         of this one only the directory named. The fixtures stay in scope either way: they are the
    ///         template a local run's copy shadows.
    /// @dev    Internal rather than private for the table test in `ChainConfig.t.sol`: it decides which
    ///         deployment's addresses a run reads, and the environment variable it answers for is process-wide,
    ///         so the rule is checked as the pure function it is rather than through `pathOf`
    function inScope(string memory root, string memory scope) internal pure returns (bool) {
        if (bytes(scope).length == 0 || vm.indexOf(root, FIXTURE_ROOT) == 0) return true;

        // `env/testnet-rev2/` → `testnet-rev2`: the segment after `env/`, not everything that is not `env/` —
        // `vm.replace` strips every occurrence, and an id may end in `env`
        string memory environment = vm.split(root, "/")[1];
        if (keccak256(bytes(baseEnvironmentOf(environment))) != keccak256(bytes(baseEnvironmentOf(scope)))) {
            return true;
        }
        return keccak256(bytes(environment)) == keccak256(bytes(scope));
    }

    /// @dev Whether two hits for one name are the sanctioned pair: a run's copy under `env/anvil-<id>/` and
    ///      the fixture under `script/anvil/env/` it was copied from, in either order — `configRoots()`
    ///      lists the directories as the filesystem hands them over, so neither comes first reliably. Only
    ///      a local run's directory may shadow a fixture: a config of the same name under any other
    ///      environment is a real collision, and is reported as one.
    function _isFixtureShadow(string memory first, string memory second) private pure returns (bool) {
        if (vm.indexOf(first, FIXTURE_ROOT) == 0) return _isLocalRun(second);
        if (vm.indexOf(second, FIXTURE_ROOT) == 0) return _isLocalRun(first);
        return false;
    }

    /// @dev Whether a config path sits in a local run's directory, `env/anvil-<id>/<network>.json`: the
    ///      environment the fixtures declare, whatever id the run added to it
    function _isLocalRun(string memory path) private pure returns (bool) {
        string[] memory parts = vm.split(path, "/");
        if (parts.length < 3 || keccak256(bytes(parts[0])) != keccak256("env")) return false;

        return keccak256(bytes(baseEnvironmentOf(parts[1]))) == keccak256(bytes(FIXTURE_ENVIRONMENT));
    }

    /// @notice Where an environment's connections file lives, beside the configs it connects.
    ///
    /// @dev    `env/<environment>/` first, then a root that is not under `env/` at all — the fixtures, which
    ///         hold one environment's chains and its connections file together. Only the `env/` root named
    ///         after the environment can answer for it, or a testnet run would read mainnet's connections.
    function connectionsPathOf(string memory environment) internal view returns (string memory) {
        string memory owned = string.concat("env/", environment, "/connections.json");
        if (_readable(owned)) return owned;

        string[] memory roots = configRoots();
        for (uint256 i; i < roots.length; i++) {
            if (vm.indexOf(roots[i], "env/") == 0) continue;
            // A fixture root answers only for the environment its own chains declare — the directory names
            // it (`script/anvil/env/` for anvil). Without this, a mainnet run whose connections file went
            // missing would silently read the two-chain local topology instead of reverting below
            if (vm.indexOf(roots[i], string.concat("/", environment, "/")) == NOT_FOUND) continue;

            string memory fixturePath = string.concat(roots[i], "connections.json");
            if (_readable(fixturePath)) return fixturePath;
        }

        revert(string.concat("No connections file for environment ", environment));
    }

    /// @notice What a config root holds, or nothing when the root is not there — `env/anvil-<id>/` exists only
    ///         after a local run, and `env/testnet/` only on the branch that owns those deployments.
    function entriesOf(string memory root) internal view returns (Vm.DirEntry[] memory) {
        try vm.readDir(root) returns (Vm.DirEntry[] memory entries) {
            return entries;
        } catch {
            return new Vm.DirEntry[](0);
        }
    }

    /// @dev `vm.exists` would read better, but it is not a view cheatcode, and making this whole stack
    ///      non-view to ask whether a file is there would reach every script that loads a config
    function _readable(string memory path) private view returns (bool) {
        try vm.readFile(path) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    function load(string memory network) internal view returns (ChainConfig memory) {
        return parse(jsonOf(network), network);
    }

    /// @notice Same, from JSON already read: what `Env` uses so a full load opens the file once
    function parse(string memory json, string memory network) internal pure returns (ChainConfig memory config) {
        config.network = _parseNetworkConfig(json);
        config.network.name = network;
        config.network.deploymentId = deploymentIdOf(config.network.environment);
        config.adapters = _parseAdaptersConfig(json);
    }

    /// @notice What an environment names beyond the base one: `testnet-rev2` is `rev2`, `testnet` is
    ///         nothing. Split at the first `-`, so an id may hold as many as it likes.
    function deploymentIdOf(string memory environment) internal pure returns (string memory) {
        uint256 dash = vm.indexOf(environment, "-");
        if (dash == NOT_FOUND) return "";

        return _slice(environment, dash + 1, bytes(environment).length);
    }

    /// @notice The environment a deployment belongs to whatever id it carries: `testnet-rev2` is `testnet`.
    ///         What decides policy — mainnet is mainnet however many deployments it holds — while the whole
    ///         string decides where the config lives.
    function baseEnvironmentOf(string memory environment) internal pure returns (string memory) {
        uint256 dash = vm.indexOf(environment, "-");
        if (dash == NOT_FOUND) return environment;

        return _slice(environment, 0, dash);
    }

    /// @notice The `Root` a config records under `.contracts`, or zero where it records none.
    /// @dev    The JSON-taking half of `ChainConfigLib.rootAddress`, as `parse` is of `load`.
    function parseRootAddress(string memory json) internal pure returns (address) {
        try vm.parseJsonAddress(json, ".contracts.root.address") returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    /// @notice The network name `block.chainid` belongs to. Walks every root `configRoots()` names — so a
    ///         local run's copies under env/anvil-<id>/ and the fixtures they came from are both reachable — and
    ///         skips anything that is not a network config (the connections files carry no chainId).
    ///
    /// @dev    There is deliberately no override: the chain the RPC points at is the single source of truth,
    ///         so a script cannot be pointed at one chain while reading another's addresses. A script that
    ///         has to choose a network *before* it has a chain — one that reads a config to know where to
    ///         fork — passes the name to `load(name)` instead.
    function detect() internal view returns (string memory) {
        // readDir answers with absolute paths; everything below reasons relative to the project root
        string memory root = string.concat(vm.projectRoot(), "/");

        string memory name;
        string memory foundAt;

        string memory scope = _scope();
        string[] memory roots = configRoots();
        for (uint256 r; r < roots.length; r++) {
            if (!inScope(roots[r], scope)) continue;

            Vm.DirEntry[] memory entries = entriesOf(roots[r]);
            for (uint256 i; i < entries.length; i++) {
                if (entries[i].isDir) continue;

                string memory path = vm.replace(entries[i].path, root, "");
                if (!_isJson(path)) continue;

                string memory json = vm.readFile(entries[i].path);
                if (!vm.keyExistsJson(json, ".network.chainId")) continue;
                if (vm.parseJsonUint(json, ".network.chainId") != block.chainid) continue;

                // The directory a config sits in restates its own `.network.environment`, so the name is
                // just the file: `local-a`, whether it is filed under an environment or copied in as a fixture
                string memory here = vm.replace(vm.replace(path, roots[r], ""), ".json", "");

                // A second answer is not a tie to break: one of them is a deployment the run did not mean,
                // and picking either silently is how a rev gets deployed over. The fixtures are the one
                // sanctioned pair, being the template a run's own copy came from
                if (bytes(foundAt).length != 0 && !_isFixtureShadow(foundAt, path)) {
                    revert(
                        string.concat(
                            "Chain ",
                            vm.toString(block.chainid),
                            " is described by ",
                            foundAt,
                            " and ",
                            path,
                            ": pass DEPLOY_ENVIRONMENT=<environment> to say which deployment this run is for.",
                            " That tells apart deployments of one environment only; if these two are of",
                            " different environments, one of the configs is wrong"
                        )
                    );
                }

                if (bytes(foundAt).length == 0) (name, foundAt) = (here, path);
            }
        }

        if (bytes(foundAt).length != 0) return name;

        revert(
            string.concat(
                "No env config for chain ",
                vm.toString(block.chainid),
                ": add env/<environment>/<network>.json naming that chainId (the environment must be one",
                " environments() lists), and point --rpc-url at it. A set DEPLOY_ENVIRONMENT hides only the other",
                " deployments of its own environment; every other environment stays in the search"
            )
        );
    }

    /// @dev The only filter the walk needs, and it is not optional: `keyExistsJson` *reverts* on anything
    ///      that is not JSON, so a stray non-JSON file would end the walk rather than be skipped by it.
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
        config.namespace = vm.parseJsonAddress(json, ".network.namespace");

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
}

library ChainConfigLib {
    /// @dev LayerZero `UlnBase.NIL_DVN_COUNT` sentinel: explicitly opts out of optional DVNs
    ///      (vs `0` which means "inherit the endpoint default optional DVN set")
    uint8 internal constant NIL_DVN_COUNT = type(uint8).max;

    /// @dev LayerZero `MessageLib` config type for `UlnConfig`.
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    /// @notice The `Root` the chain's config records, or zero where it records none.
    ///
    /// @dev    The one deployed address `ChainConfig` answers for, because `ContractsConfig` cannot: until a
    ///         release is deployed a config records `contracts.root` and nothing else, which
    ///         `Env.parseContracts` rejects. Re-reads the file, a `ChainConfig` carrying no JSON
    function rootAddress(ChainConfig memory config) internal view returns (address) {
        return Chains.parseRootAddress(Chains.jsonOf(config.network.name));
    }

    /// @dev Live-branch consumer only (see `GraphQLConstants`). The ignored receiver is the attachment
    ///      point: it exists so a caller writes `config.chain.etherscanApiKey()` through `using`.
    function etherscanApiKey(ChainConfig memory) internal view returns (string memory) {
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

    function buildLayerZeroConfigParams(ChainConfig memory config)
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

            ChainConfig memory remoteConfig = Chains.load(connections[i].network);

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

    function adapterConnections(ChainConfig memory config)
        internal
        view
        returns (AdapterConnections[] memory adapterConnections_)
    {
        Connection[] memory connections = config.network.connections();
        adapterConnections_ = new AdapterConnections[](connections.length);

        for (uint256 i; i < connections.length; i++) {
            ChainConfig memory remoteConfig = Chains.load(connections[i].network);
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
            ChainConfig memory remoteConfig = Chains.load(connections_[i].network);

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
    /// @dev Live-branch consumer only (see `GraphQLConstants`)
    function rpcUrl(NetworkConfig memory config) internal view returns (string memory) {
        return vm.rpcUrl(config.name);
    }

    function isMainnet(NetworkConfig memory config) internal pure returns (bool) {
        return keccak256(bytes(Chains.baseEnvironmentOf(config.environment))) == keccak256("mainnet");
    }

    /// @dev Live-branch consumer only (see `GraphQLConstants`)
    function graphQLApi(NetworkConfig memory config) internal pure returns (string memory) {
        return config.isMainnet() ? GraphQLConstants.MAINNET_API : GraphQLConstants.TESTNET_API;
    }
}

/// @dev Live-branch consumer only (see `GraphQLConstants`)
function prettyEnvString(string memory name) view returns (string memory value) {
    value = vm.envOr(name, string(""));
    if (bytes(value).length == 0) revert(string.concat("Missing env var: ", name));
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainConfig, Chains} from "../../../script/utils/ChainConfig.s.sol";

import "forge-std/Test.sol";

/// @dev Lists what `env/` actually holds, independently of `Chains.detect()`, whose filtering is one of the
///      things these tests are here to check.
///
///      No network is named anywhere in this file, on purpose. What is under test is the shape of an
///      `env/<environment>/<network>.json` — which fields a config must carry, what it gets for the ones it leaves out,
///      that a name resolves to exactly one chain — and none of that is a statement about the values a live
///      deployment happens to carry in those fields today. Those are `EnvConfig.t.sol`'s subject: which
///      networks exist, which id each took, where each explorer is, what is deployed and how it is wired.
///      So the directory is walked rather than listed, and a network that is added is covered by the shape
///      tests without anyone remembering to add it.
/// @notice The walk every directory-driven config test shares.
///
/// @dev    Configs come from the roots `Chains.configRoots()` names, so this covers whatever the branch
///         holds: two anvil fixtures here, every real network on `live`, and both without either side
///         being edited. Each config is handed over with the deployment it sits in, because the name alone
///         no longer picks one out: a second deployment of the same chains — `env/testnet-rev2/` beside
///         `env/testnet/`, or a local run's copy beside the fixture it came from — carries the same names,
///         and reading one of them under no deployment in particular is exactly the ambiguity
///         `Chains.pathOf` refuses. So every read is `Chains.load(name, environment)`, and the fixture and
///         its copy are both walked, each under its own.
///
///         Not everything under those roots describes a chain — the connections files parse fine and name
///         none — so the chainId key is what tells them apart. That is the one filter `Chains.detect()`
///         also applies, which is as far as this can stay independent of it.
abstract contract ChainConfigBase is Test {
    /// @dev One config as the walk sees it: the name a run reaches it by, and the deployment to read it under
    struct ConfigRef {
        string name;
        string environment;
    }

    /// @dev What `vm.indexOf` answers when the key is not in the string
    uint256 internal constant NOT_FOUND = type(uint256).max;

    function _configs() internal view returns (ConfigRef[] memory) {
        string[] memory roots = Chains.configRoots();

        uint256 count;
        ConfigRef[] memory configs = new ConfigRef[](64);
        for (uint256 r; r < roots.length; r++) {
            Vm.DirEntry[] memory entries = Chains.entriesOf(roots[r]);
            string memory environment = Chains.environmentOf(roots[r]);

            for (uint256 i; i < entries.length; i++) {
                if (entries[i].isDir) continue;

                string memory file = vm.replace(entries[i].path, string.concat(vm.projectRoot(), "/"), "");
                // Anchored to the end, so a `.json.bak` left lying around is not read as a config
                uint256 at = vm.indexOf(file, ".json");
                if (at == NOT_FOUND || at != bytes(file).length - 5) continue;

                string memory json = vm.readFile(entries[i].path);
                if (!vm.keyExistsJson(json, ".network.chainId")) continue;

                string memory name = vm.replace(vm.replace(file, roots[r], ""), ".json", "");
                configs[count++] = ConfigRef(name, environment);
            }
        }
        return _truncate(configs, count);
    }

    /// @dev How a failure names a config: by deployment as well as name, since a name may be in several
    function _label(ConfigRef memory config) internal pure returns (string memory) {
        return string.concat(config.environment, "/", config.name);
    }

    function _truncate(ConfigRef[] memory configs, uint256 count) private pure returns (ConfigRef[] memory found) {
        found = new ConfigRef[](count);
        for (uint256 i; i < count; i++) {
            found[i] = configs[i];
        }
    }
}

contract ChainConfigTest is ChainConfigBase {
    string constant ETHERSCAN_V2 = "https://api.etherscan.io/v2/api?chainid=";

    /// @dev Everything `.network` requires and nothing it does not, so what the parser fills in by itself is
    ///      whatever this does not say
    string constant MINIMAL = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002",'
        '"namespace":"0x0000000000000000000000000000000000000003"}}';

    /// @dev The same, naming a verification endpoint that answers nothing but submissions
    string constant WITH_VERIFIER = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002",'
        '"namespace":"0x0000000000000000000000000000000000000003",'
        '"verifier":"etherscan","verifierUrl":"https://write-only.example/api"}}';

    /// @dev A `.contracts` section with the Root in it, and a neighbour, so the lookup has to pick one
    string constant WITH_ROOT = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"},'
        '"contracts":{"spoke":{"address":"0x0000000000000000000000000000000000000004"},'
        '"root":{"address":"0x0000000000000000000000000000000000000003","version":"v3.3"}}}';

    /// @dev The same with the Root taken out, which is a config a launch is meant to bring one up on
    string constant WITHOUT_ROOT = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"},'
        '"contracts":{"spoke":{"address":"0x0000000000000000000000000000000000000004"}}}';

    /// @dev The four ways a config can record a Root it cannot hand over. Each has a `.contracts.root`, so
    ///      each means to keep one, and none of them names an address a launch could wire the protocol to
    string constant MALFORMED_ROOT = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"},'
        '"contracts":{"root":{"address":"0xnot-an-address"}}}';

    string constant ROOT_WITHOUT_ADDRESS = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"},' '"contracts":{"root":{"blockNumber":1}}}';

    string constant NULL_ROOT = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"},' '"contracts":{"root":null}}';

    string constant ZERO_ROOT = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"},'
        '"contracts":{"root":{"address":"0x0000000000000000000000000000000000000000"}}}';

    /// @dev A config carries the name it was read under, not one it names itself: `detect()` derives the
    ///      name from the path, and everything downstream — the rpc alias, the connections lookup — keys off
    ///      it, so a config could not disagree about who it is even if it tried.
    function test_parseTakesTheNameFromTheCaller() public pure {
        assertEq(Chains.parse(MINIMAL, "somewhere").network.name, "somewhere");
    }

    /// @dev What a config may leave out, and what it then gets. `batchLimit` at 0 is the one that is not a
    ///      fallback but an absence: a peer that names none contributes no limit to `buildBatchLimits`.
    function test_parseFillsTheOptionalFieldsIn() public pure {
        ChainConfig memory config = Chains.parse(MINIMAL, "somewhere");

        assertEq(config.network.batchLimit, 0);
        assertEq(config.network.verifier, "");
        assertEq(config.network.verifierUrl, string.concat(ETHERSCAN_V2, "424242"));
        assertEq(config.network.explorerApiUrl, string.concat(ETHERSCAN_V2, "424242"));

        assertFalse(config.adapters.layerZero.deploy);
        assertFalse(config.adapters.axelar.deploy);
        assertFalse(config.adapters.chainlink.deploy);
        assertFalse(config.adapters.hyperlane.deploy);
    }

    /// @dev `verifierUrl` (where source is submitted) and `explorerApiUrl` (where chain data is read) are two
    ///      different services on the Blockscout-family explorers, and conflating them is silent: the deploy
    ///      scripts record no block, and the verification flow reports every contract as unverified. So a
    ///      config that names only a verifier must not have it stand in for the read URL — the fallback is
    ///      Etherscan by chain id, never the endpoint next to it.
    function test_explorerApiUrlNeverFallsBackToTheVerifier() public pure {
        ChainConfig memory config = Chains.parse(WITH_VERIFIER, "somewhere");

        assertEq(config.network.verifierUrl, "https://write-only.example/api");
        assertEq(config.network.explorerApiUrl, string.concat(ETHERSCAN_V2, "424242"));
    }

    /// @dev The fields with no default are required outright: a config missing one has to fail where it is
    ///      read, not deploy against a zero
    function test_parseRequiresTheFieldsWithoutDefaults() public {
        string[6] memory required = ["chainId", "environment", "centrifugeId", "protocolAdmin", "opsAdmin", "namespace"];

        for (uint256 i; i < required.length; i++) {
            // Renamed rather than cut out, so the JSON stays JSON and it is the key that is gone
            string memory without = vm.replace(MINIMAL, string.concat('"', required[i], '"'), '"renamed"');

            vm.expectRevert();
            this.parse(without);
        }
    }

    /// @dev `Root` is the one `.contracts` entry the chain half reads, because keeping it is what decides
    ///      whether a launch lands beside the Root a chain already has or stands a second one next to it.
    function test_rootAddressIsWhatTheConfigRecords() public view {
        assertEq(Chains.parseRootAddress(WITH_ROOT), address(3));
    }

    /// @dev Absent is an answer, not a failure: it is what a chain being prepared looks like, and what tells a
    ///      launch to deploy its own. Zero whether the section is missing or merely has no Root in it — a
    ///      revert either way would make every such config undeployable.
    function test_rootAddressIsZeroWhereNoneIsRecorded() public view {
        assertEq(Chains.parseRootAddress(WITHOUT_ROOT), address(0), "a contracts section with no root");
        assertEq(Chains.parseRootAddress(MINIMAL), address(0), "no contracts section at all");
    }

    /// @dev Only the absent Root is zero. One that is recorded and unreadable has to fail where it is read:
    ///      answering zero would deploy a second Root beside the one this chain already carries, and wire the
    ///      whole protocol to it. A zero address is the one that needs saying out loud — it parses fine, and
    ///      is exactly the value that means "no Root recorded"
    function test_rootAddressRevertsOnARootItCannotRead() public {
        vm.expectRevert();
        this.rootAddress(MALFORMED_ROOT);

        vm.expectRevert();
        this.rootAddress(ROOT_WITHOUT_ADDRESS);

        vm.expectRevert();
        this.rootAddress(NULL_ROOT);

        vm.expectRevert("config records a zero Root: delete .contracts.root to deploy one");
        this.rootAddress(ZERO_ROOT);
    }

    /// @dev An external hop, as `parse` above, so `vm.expectRevert` sees the revert below its own depth
    function rootAddress(string memory json) external view returns (address) {
        return Chains.parseRootAddress(json);
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function parse(string memory json) external pure returns (ChainConfig memory) {
        return Chains.parse(json, "somewhere");
    }
}

/// @dev `Chains.detect()` is what turns `--rpc-url <network>` into the config a deploy script reads, so a
///      mistake here does not fail — it silently deploys against another chain's addresses. Every config is
///      matched by its own chain id, which also covers the path filter: a manifest under env/latest/ or a
///      connections file mistaken for a config would answer the wrong name, or none at all.
contract ChainConfigDeploymentIdTest is ChainConfigBase {
    /// @dev The environment names the directory a config sits in, and a deployment id is the part of that
    ///      name after the first `-`: one string, two readings, so the two can never disagree
    function test_deploymentIdIsTheTailOfTheEnvironment() public pure {
        assertEq(Chains.deploymentIdOf("testnet"), "", "the canonical deployment carries no id");
        assertEq(Chains.deploymentIdOf("testnet-rev2"), "rev2");
        assertEq(Chains.deploymentIdOf("anvil-1787683343"), "1787683343");
        assertEq(Chains.deploymentIdOf("testnet-rev-2"), "rev-2", "the id may hold dashes of its own");
    }

    /// @dev `DEPLOY_ENVIRONMENT` settles one question — which of several deployments of one base environment a
    ///      run means — and no other: the roots of every other base environment stay readable, and the
    ///      fixtures always do, being the template a local run's copy shadows. Table-tested as the pure
    ///      function it is: the variable it answers for is process-wide, so setting it in a test would race
    ///      every other test that walks the roots.
    function test_scopeHidesOnlyTheSiblingDeploymentsOfItsOwnEnvironment() public pure {
        // Unset: nothing is hidden
        assertTrue(Chains.inScope("env/testnet/", ""));
        assertTrue(Chains.inScope("env/mainnet/", ""));

        // Named: the directory itself, every other base environment, and the fixtures stay
        assertTrue(Chains.inScope("env/testnet-rev2/", "testnet-rev2"));
        assertTrue(Chains.inScope("env/mainnet/", "testnet-rev2"), "another base environment is not narrowed");
        assertTrue(Chains.inScope("env/anvil-1787683343/", "testnet-rev2"), "nor is a local run's copy");
        assertTrue(Chains.inScope(Chains.FIXTURE_ROOT, "testnet-rev2"), "the fixtures are always in scope");

        // Named: the siblings under the same base environment go, in both directions
        assertFalse(Chains.inScope("env/testnet/", "testnet-rev2"), "the canonical deployment is a sibling");
        assertFalse(Chains.inScope("env/testnet-rev2/", "testnet"), "and so is a rev, seen from it");
        assertFalse(Chains.inScope("env/anvil-1787683343/", "anvil-1787683344"), "two local runs are siblings");

        // The environment is the path segment after `env/`, whatever the id is made of
        assertTrue(Chains.inScope("env/testnet-env/", "testnet-env"), "an id may end in `env`");
        assertTrue(Chains.inScope("env/testnet-rev-2/", "testnet-rev-2"), "or hold dashes of its own");
        assertFalse(Chains.inScope("env/testnet-rev-2/", "testnet-rev"), "and a prefix of it is not it");
    }

    /// @dev What a walk reads a root's configs under: the directory itself, id and all — and for the one
    ///      root outside `env/`, the environment the fixtures declare
    function test_environmentOfARootIsItsDirectory() public pure {
        assertEq(Chains.environmentOf("env/testnet/"), "testnet");
        assertEq(Chains.environmentOf("env/testnet-rev2/"), "testnet-rev2");
        assertEq(Chains.environmentOf("env/anvil-1787683343/"), "anvil-1787683343");
        assertEq(Chains.environmentOf(Chains.FIXTURE_ROOT), Chains.FIXTURE_ENVIRONMENT);
    }

    /// @dev And the way back: where a read that names its deployment looks, without probing the other roots
    function test_rootOfAnEnvironmentIsItsDirectory() public pure {
        assertEq(Chains.rootOf("testnet"), "env/testnet/");
        assertEq(Chains.rootOf("testnet-rev2"), "env/testnet-rev2/");
        assertEq(Chains.rootOf("anvil-1787683343"), "env/anvil-1787683343/");
        assertEq(Chains.rootOf(Chains.FIXTURE_ENVIRONMENT), Chains.FIXTURE_ROOT, "the fixtures are not under env/");
    }

    /// @dev A read that names its deployment gets that deployment's file or nothing. `DEPLOY_ENVIRONMENT`
    ///      narrows — it hides the siblings and leaves every other base environment readable — and that is
    ///      the rule for the one config a run is addressed by, not for a peer its connections file names:
    ///      answering a testnet's peer with a config only `env/mainnet/` carries would wire the testnet to
    ///      mainnet's centrifugeId and addresses without a word. The fixtures make the case here, being the
    ///      one root every scope leaves in.
    function test_aNamedDeploymentAnswersOnlyWithItsOwnConfigs() public {
        assertEq(
            Chains.pathOf("local-a", Chains.FIXTURE_ENVIRONMENT),
            string.concat(Chains.FIXTURE_ROOT, "local-a.json"),
            "the deployment that carries the name answers"
        );

        vm.expectRevert(bytes("No config named local-a in environment testnet: expected env/testnet/local-a.json"));
        this.pathOf("local-a", "testnet");
    }

    /// @dev `expectRevert` needs a call boundary, and `Chains` is a library
    function pathOf(string memory network, string memory environment) external view returns (string memory) {
        return Chains.pathOf(network, environment);
    }

    /// @dev What policy reads: mainnet is mainnet however many deployments it holds
    function test_baseEnvironmentIsTheHeadOfIt() public pure {
        assertEq(Chains.baseEnvironmentOf("testnet"), "testnet");
        assertEq(Chains.baseEnvironmentOf("testnet-rev2"), "testnet");
        assertEq(Chains.baseEnvironmentOf("anvil-1787683343"), "anvil");
    }

    /// @dev A parsed config carries the id its environment names, without a field of its own to disagree
    function test_parseDerivesTheDeploymentId() public pure {
        ChainConfig memory config = Chains.parse(
            '{"network":{"chainId":424242,"environment":"testnet-rev2","centrifugeId":31,'
            '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
            '"opsAdmin":"0x0000000000000000000000000000000000000002",'
            '"namespace":"0x0000000000000000000000000000000000000003"}}',
            "somewhere"
        );

        assertEq(config.network.environment, "testnet-rev2");
        assertEq(config.network.deploymentId, "rev2");
        assertFalse(config.network.isMainnet(), "a testnet rev is not mainnet");
    }
}

contract ChainConfigDirectoryTest is ChainConfigBase {
    /// @dev Every config states the directory it sits in, so the pair can be checked on every read: a
    ///      directory renamed without the field, or a rev copied without editing it, would otherwise move
    ///      every address the chain deploys to and say nothing about it.
    ///
    ///      The fixtures are the exception, declaring an environment no directory under `env/` carries — so
    ///      what is asserted of them is the other half: read under that environment they answer themselves,
    ///      not the copy a local run may have left beside them, which is a sibling and out of scope.
    function test_everyConfigRestatesItsDirectory() public view {
        ConfigRef[] memory configs = _configs();

        for (uint256 i; i < configs.length; i++) {
            string memory path = Chains.pathOf(configs[i].name, configs[i].environment);
            string memory label = _label(configs[i]);

            if (_is(configs[i].environment, Chains.FIXTURE_ENVIRONMENT)) {
                assertEq(path, string.concat(Chains.FIXTURE_ROOT, configs[i].name, ".json"), label);
                continue;
            }

            ChainConfig memory config = Chains.load(configs[i].name, configs[i].environment);
            assertEq(path, string.concat("env/", config.network.environment, "/", configs[i].name, ".json"), label);
        }
    }

    /// @dev A directory under `env/` is an environment `Chains.environments()` names, with or without a
    ///      deployment id after it, or the spell archive. `configRoots()` leaves anything else out rather
    ///      than failing on it, so a typo — `env/tesnet-rev2/` — would otherwise be a directory of configs no
    ///      run can reach, failing only as "no config for this chain"; this is what makes it fail by name.
    function test_everyDirectoryUnderEnvIsAnEnvironment() public view {
        Vm.DirEntry[] memory entries = Chains.entriesOf("env/");

        for (uint256 i; i < entries.length; i++) {
            if (!entries[i].isDir) continue;

            string memory name = _fileName(entries[i].path);
            if (keccak256(bytes(name)) == keccak256("spell")) continue;

            assertTrue(
                Chains.isEnvironment(Chains.baseEnvironmentOf(name)),
                string.concat("env/", name, "/ is named after no environment Chains.environments() lists")
            );
        }
    }

    /// @dev Every field a script reads off the chain half is required, so a config that parses is a config a
    ///      deployment can be pointed at. Vacuous on a branch holding no configs, which is the point: the
    ///      rule belongs with the parser, the configs it is applied to belong with the deployments.
    function test_everyConfigParses() public view {
        ConfigRef[] memory configs = _configs();

        for (uint256 i; i < configs.length; i++) {
            ChainConfig memory config = Chains.load(configs[i].name, configs[i].environment);
            string memory label = _label(configs[i]);

            assertEq(config.network.name, configs[i].name, label);
            assertGt(config.network.chainId, 0, label);
            assertGt(config.network.centrifugeId, 0, label);
            assertGt(bytes(config.network.environment).length, 0, label);
            assertNotEq(config.network.protocolAdmin, address(0), label);
            assertNotEq(config.network.opsAdmin, address(0), label);
            assertNotEq(config.network.namespace, address(0), label);
            assertGt(bytes(config.network.explorerApiUrl).length, 0, label);
        }
    }

    /// @dev The canary for the whole directory-driven family: the fixtures exist on every branch, so a
    ///      walk that sees fewer than both local chains means a root went unreadable — an fs_permissions
    ///      entry lost, say — and `entriesOf`'s catch would otherwise convert that into every test above
    ///      passing vacuously over an empty list.
    function test_theWalkAlwaysSeesTheFixtures() public view {
        assertGe(_configs().length, 2, "the config walk is blind: check fs_permissions for the roots");
    }

    /// @dev The name is the key a run reaches a chain by, `--rpc-url <network>`, and it may resolve to more
    ///      than one config: `env/testnet/<network>.json` beside `env/testnet-rev2/<network>.json` is what a
    ///      second deployment of a chain looks like, and `DEPLOY_ENVIRONMENT` is how a run picks between them. That
    ///      only holds while every config of one name describes one chain: `DEPLOY_ENVIRONMENT` tells apart the
    ///      deployments of one environment and nothing else, so a testnet acquiring a config named like one of
    ///      a mainnet's would leave the name unresolvable — `pathOf` reverts as ambiguous under every value —
    ///      and with it every remote-config read the connections make. Fail-closed, and this is what says why.
    ///      Walked by root rather than through `_configs()`, because the collision is between roots: what
    ///      has to be compared is the twin a name has under another root, not each config on its own.
    function test_aNameResolvesToOneChain() public view {
        string[] memory roots = Chains.configRoots();

        for (uint256 i; i < roots.length; i++) {
            Vm.DirEntry[] memory entries = Chains.entriesOf(roots[i]);

            for (uint256 e; e < entries.length; e++) {
                if (entries[e].isDir || !_isConfig(entries[e].path)) continue;

                for (uint256 j = i + 1; j < roots.length; j++) {
                    string memory name = _fileName(entries[e].path);
                    string memory twin = string.concat(roots[j], name);
                    if (!_exists(twin)) continue;

                    assertEq(
                        _chainIdOf(entries[e].path),
                        _chainIdOf(twin),
                        string.concat(name, " names two chains: ", roots[i], " and ", roots[j])
                    );
                }
            }
        }
    }

    function _chainIdOf(string memory path) private view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(path), ".network.chainId");
    }

    function _isConfig(string memory path) private view returns (bool) {
        uint256 at = vm.indexOf(path, ".json");
        if (at == NOT_FOUND || at != bytes(path).length - 5) return false;
        return vm.keyExistsJson(vm.readFile(path), ".network.chainId");
    }

    function _fileName(string memory path) private pure returns (string memory) {
        bytes memory b = bytes(path);
        uint256 cut;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == "/") cut = i + 1;
        }
        bytes memory out = new bytes(b.length - cut);
        for (uint256 i; i < out.length; i++) {
            out[i] = b[cut + i];
        }
        return string(out);
    }

    function _exists(string memory path) private view returns (bool) {
        try vm.readFile(path) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev `Chains.detect()` answers by chain id, so two configs claiming one chain would make which config
    ///      a run reads depend on directory order — unless they are two deployments of that chain, the one
    ///      shape allowed to share an id: `env/testnet/` beside `env/testnet-rev2/`, or the fixture beside a
    ///      local run's copy of it, each hidden from the other by the deployment a run names. Across base
    ///      environments the id has to be unique outright, because that is the one distinction
    ///      `DEPLOY_ENVIRONMENT` never draws: a testnet claiming a mainnet's chain would leave `detect()` with
    ///      two answers under every value of it.
    function test_chainIdsAreUnique() public view {
        ConfigRef[] memory configs = _configs();

        // One load per config: `Chains.load` is an internal call, so the pairwise form would accumulate
        // 2n(n-1) full config reads in this frame — harmless on two fixtures, needless on live's seventeen
        uint256[] memory ids = new uint256[](configs.length);
        for (uint256 i; i < configs.length; i++) {
            ids[i] = Chains.load(configs[i].name, configs[i].environment).network.chainId;
        }

        for (uint256 i; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                if (ids[i] != ids[j]) continue;

                assertTrue(
                    _siblingDeployments(configs[i].environment, configs[j].environment),
                    string.concat(_label(configs[i]), " and ", _label(configs[j]), " claim the same chainId")
                );
            }
        }
    }

    /// @dev Two deployments of one base environment, and not the same one: what a run tells apart with
    ///      `DEPLOY_ENVIRONMENT`, so what may describe one chain twice
    function _siblingDeployments(string memory a, string memory b) private pure returns (bool) {
        if (_is(a, b)) return false;
        return _is(Chains.baseEnvironmentOf(a), Chains.baseEnvironmentOf(b));
    }

    function _is(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

/// @dev `connectionsPathOf` may fall back to a fixture root, but only for the environment whose chains
///      that root actually describes: the fixtures are the anvil pair, and a mainnet or testnet run whose
///      own connections file is missing must revert rather than silently wire against the two-chain local
///      topology. The environments that exist are data and differ per branch, so the assertion uses one
///      that exists nowhere.
contract ConnectionsPathTest is Test {
    function test_connectionsPathAnswersOnlyForTheFixturesOwnEnvironment() public {
        vm.expectRevert(bytes("No connections file for environment somewhere"));
        this.connectionsPathOf("somewhere");
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function connectionsPathOf(string memory environment) external view returns (string memory) {
        return Chains.connectionsPathOf(environment);
    }
}

contract ChainDetectTest is ChainConfigBase {
    /// @dev `Chains.detect()` is what turns `--rpc-url <network>` into the config a deploy script reads, so
    ///      a mistake here does not fail — it silently deploys against another chain's addresses. Each config
    ///      is detected under the deployment it sits in, as a run confined by `DEPLOY_ENVIRONMENT` would see
    ///      it: with two deployments of one chain checked in, the unconfined `detect()` has two answers and
    ///      refuses rather than picking one, which is the right behaviour for a run and no test of this.
    function test_detectsEveryNetworkByChainId() public {
        ConfigRef[] memory configs = _configs();

        for (uint256 i; i < configs.length; i++) {
            vm.chainId(Chains.load(configs[i].name, configs[i].environment).network.chainId);
            assertEq(this.detect(configs[i].environment), configs[i].name, _label(configs[i]));
        }
    }

    function test_revertsOnAChainNoConfigNames() public {
        vm.chainId(123456789);
        vm.expectRevert(
            bytes(
                "No env config for chain 123456789: add env/<environment>/<network>.json naming that chainId"
                " (the environment must be one environments() lists), and point --rpc-url at it. A set DEPLOY_ENVIRONMENT"
                " hides only the other deployments of its own environment; every other environment stays in the search"
            )
        );
        this.detect();
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function detect() external view returns (string memory) {
        return Chains.detect();
    }

    function detect(string memory environment) external view returns (string memory) {
        return Chains.detect(environment);
    }
}

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
///         being edited. Names are deduplicated with the first root winning, because a local run copies the
///         fixtures into `env/anvil/` and both copies then describe the same chain.
///
///         Not everything under those roots describes a chain — the connections files parse fine and name
///         none — so the chainId key is what tells them apart. That is the one filter `Chains.detect()`
///         also applies, which is as far as this can stay independent of it.
abstract contract ChainConfigBase is Test {
    /// @dev What `vm.indexOf` answers when the key is not in the string
    uint256 internal constant NOT_FOUND = type(uint256).max;

    function _configNames() internal view returns (string[] memory) {
        string[] memory roots = Chains.configRoots();

        uint256 count;
        string[] memory names = new string[](64);
        for (uint256 r; r < roots.length; r++) {
            Vm.DirEntry[] memory entries = Chains.entriesOf(roots[r]);

            for (uint256 i; i < entries.length; i++) {
                if (entries[i].isDir) continue;

                string memory file = vm.replace(entries[i].path, string.concat(vm.projectRoot(), "/"), "");
                // Anchored to the end, so a `.json.bak` left lying around is not read as a config
                uint256 at = vm.indexOf(file, ".json");
                if (at == NOT_FOUND || at != bytes(file).length - 5) continue;

                string memory json = vm.readFile(entries[i].path);
                if (!vm.keyExistsJson(json, ".network.chainId")) continue;

                string memory name = vm.replace(vm.replace(file, roots[r], ""), ".json", "");
                if (_seen(names, count, name)) continue;

                names[count++] = name;
            }
        }
        return _truncate(names, count);
    }

    function _seen(string[] memory names, uint256 count, string memory name) private pure returns (bool) {
        for (uint256 i; i < count; i++) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(name))) return true;
        }
        return false;
    }

    function _truncate(string[] memory names, uint256 count) private pure returns (string[] memory found) {
        found = new string[](count);
        for (uint256 i; i < count; i++) {
            found[i] = names[i];
        }
    }
}

contract ChainConfigTest is ChainConfigBase {
    string constant ETHERSCAN_V2 = "https://api.etherscan.io/v2/api?chainid=";

    /// @dev Everything `.network` requires and nothing it does not, so what the parser fills in by itself is
    ///      whatever this does not say
    string constant MINIMAL = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"}}';

    /// @dev The same, naming a verification endpoint that answers nothing but submissions
    string constant WITH_VERIFIER = '{"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002",'
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
        string[5] memory required = ["chainId", "environment", "centrifugeId", "protocolAdmin", "opsAdmin"];

        for (uint256 i; i < required.length; i++) {
            // Renamed rather than cut out, so the JSON stays JSON and it is the key that is gone
            string memory without = vm.replace(MINIMAL, string.concat('"', required[i], '"'), '"renamed"');

            vm.expectRevert();
            this.parse(without);
        }
    }

    /// @dev `Root` is the one `.contracts` entry the chain half reads, because keeping it is what decides
    ///      whether a launch lands beside the Root a chain already has or stands a second one next to it.
    function test_rootAddressIsWhatTheConfigRecords() public pure {
        assertEq(Chains.parseRootAddress(WITH_ROOT), address(3));
    }

    /// @dev Absent is an answer, not a failure: it is what a chain being prepared looks like, and what tells a
    ///      launch to deploy its own. Zero whether the section is missing or merely has no Root in it — a
    ///      revert either way would make every such config undeployable.
    function test_rootAddressIsZeroWhereNoneIsRecorded() public pure {
        assertEq(Chains.parseRootAddress(WITHOUT_ROOT), address(0), "a contracts section with no root");
        assertEq(Chains.parseRootAddress(MINIMAL), address(0), "no contracts section at all");
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
contract ChainConfigDirectoryTest is ChainConfigBase {
    /// @dev Every field a script reads off the chain half is required, so a config that parses is a config a
    ///      deployment can be pointed at. Vacuous on a branch holding no configs, which is the point: the
    ///      rule belongs with the parser, the configs it is applied to belong with the deployments.
    function test_everyConfigParses() public view {
        string[] memory names = _configNames();

        for (uint256 i; i < names.length; i++) {
            ChainConfig memory config = Chains.load(names[i]);

            assertEq(config.network.name, names[i], names[i]);
            assertGt(config.network.chainId, 0, names[i]);
            assertGt(config.network.centrifugeId, 0, names[i]);
            assertGt(bytes(config.network.environment).length, 0, names[i]);
            assertNotEq(config.network.protocolAdmin, address(0), names[i]);
            assertNotEq(config.network.opsAdmin, address(0), names[i]);
            assertGt(bytes(config.network.explorerApiUrl).length, 0, names[i]);
        }
    }

    /// @dev The canary for the whole directory-driven family: the fixtures exist on every branch, so a
    ///      walk that sees fewer than both local chains means a root went unreadable — an fs_permissions
    ///      entry lost, say — and `entriesOf`'s catch would otherwise convert that into every test above
    ///      passing vacuously over an empty list.
    function test_theWalkAlwaysSeesTheFixtures() public view {
        assertGe(_configNames().length, 2, "the config walk is blind: check fs_permissions for the roots");
    }

    /// @dev The name is `pathOf`'s primary key across environments, so it must be unique across them: a
    ///      testnet acquiring a config named like a mainnet (`monad`, say) would be one `pathOf` ambiguity
    ///      revert away from reading the wrong chain's addresses. `_configNames()` deduplicates by name —
    ///      deliberately, for the anvil copy — which is exactly why this test walks the roots itself: the
    ///      dedupe would hide the collision this exists to catch. The anvil copy over its fixture is the
    ///      one sanctioned duplicate.
    function test_networkNamesAreUniqueAcrossEnvironments() public view {
        string[] memory roots = Chains.configRoots();

        for (uint256 i; i < roots.length; i++) {
            Vm.DirEntry[] memory entries = Chains.entriesOf(roots[i]);

            for (uint256 e; e < entries.length; e++) {
                if (entries[e].isDir || !_isConfig(entries[e].path)) continue;

                for (uint256 j = i + 1; j < roots.length; j++) {
                    bool sanctioned = _isAnvilPair(roots[i], roots[j]);
                    string memory name = _fileName(entries[e].path);
                    string memory twin = string.concat(roots[j], name);

                    assertTrue(
                        sanctioned || !_exists(twin),
                        string.concat(name, " exists under both ", roots[i], " and ", roots[j])
                    );
                }
            }
        }
    }

    function _isAnvilPair(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes("env/anvil/"))
            && keccak256(bytes(b)) == keccak256(bytes("script/anvil/env/"));
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
    ///      a run reads depend on directory order.
    function test_chainIdsAreUnique() public view {
        string[] memory names = _configNames();

        // One load per name: `Chains.load` is an internal call, so the pairwise form would accumulate
        // 2n(n-1) full config reads in this frame — harmless on two fixtures, needless on live's seventeen
        uint256[] memory ids = new uint256[](names.length);
        for (uint256 i; i < names.length; i++) {
            ids[i] = Chains.load(names[i]).network.chainId;
        }

        for (uint256 i; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                assertTrue(ids[i] != ids[j], string.concat(names[i], " and ", names[j], " claim the same chainId"));
            }
        }
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
    ///      a mistake here does not fail — it silently deploys against another chain's addresses.
    function test_detectsEveryNetworkByChainId() public {
        string[] memory names = _configNames();

        for (uint256 i; i < names.length; i++) {
            vm.chainId(Chains.load(names[i]).network.chainId);
            assertEq(this.detect(), names[i], names[i]);
        }
    }

    function test_revertsOnAChainNoConfigNames() public {
        vm.chainId(123456789);
        vm.expectRevert(
            bytes(
                "No env config for chain 123456789: add env/<environment>/<network>.json naming that chainId"
                " (the environment must be one configRoots() lists), and point --rpc-url at it"
            )
        );
        this.detect();
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function detect() external view returns (string memory) {
        return Chains.detect();
    }
}

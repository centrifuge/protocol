// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnvConfig, Env, Connection} from "../../../script/utils/EnvConfig.s.sol";
import {EnvConnections, EnvConnectionsConfig} from "../../../script/utils/EnvConnectionsConfig.s.sol";

import "forge-std/Test.sol";

/// @dev Lists what `env/` actually holds, independently of `Env.detect()`, whose filtering is one of the
///      things these tests are here to check.
abstract contract EnvFilesBase is Test {
    /// @dev What `vm.indexOf` answers when the key is not in the string
    uint256 internal constant NOT_FOUND = type(uint256).max;

    /// @notice Every env/<network>.json, by name, read off the directory rather than listed by hand: a
    ///         network that is added has to be covered by these tests without anyone remembering to add it.
    function _configNames() internal view returns (string[] memory names) {
        string memory prefix = string.concat(vm.projectRoot(), "/env/");
        Vm.DirEntry[] memory entries = vm.readDir("env");

        uint256 count;
        names = new string[](entries.length);
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].isDir) continue;

            string memory file = vm.replace(entries[i].path, prefix, "");
            if (!_isJson(file)) continue;

            names[count++] = vm.replace(file, ".json", "");
        }

        string[] memory found = new string[](count);
        for (uint256 i; i < count; i++) {
            found[i] = names[i];
        }
        return found;
    }

    /// @dev Anchored to the end, so a `.json.bak` left lying around is not read as a config
    function _isJson(string memory file) private pure returns (bool) {
        uint256 at = vm.indexOf(file, ".json");
        return at != NOT_FOUND && at == bytes(file).length - 5;
    }
}

/// @dev Parsing a config is most of what there is to validate: every field a script reads is required, so a
///      config that parses is a config a deployment can run against.
contract EnvFilesTest is EnvFilesBase {
    struct Pinned {
        string network;
        uint16 centrifugeId;
    }

    function test_everyConfigParses() public view {
        string[] memory names = _configNames();
        assertGt(names.length, 0, "no configs found under env/");

        for (uint256 i; i < names.length; i++) {
            EnvConfig memory config = Env.load(names[i]);
            config.network.buildBatchLimits();

            assertGt(config.network.chainId, 0, names[i]);
            assertGt(config.network.centrifugeId, 0, names[i]);
        }
    }

    /// @dev A centrifugeId is carried by every PoolId and AssetId minted from that chain, so a config that
    ///      renumbers one is not a config change but a different protocol. Pinned here, and the table is
    ///      asserted complete against `env/`, so a network cannot arrive without declaring which id it takes.
    function test_centrifugeIdsAreTheOnesAlreadyInUse() public view {
        Pinned[] memory pinned = _pinnedIds();
        assertEq(_configNames().length, pinned.length, "a network was added or removed without updating _pinnedIds");

        for (uint256 i; i < pinned.length; i++) {
            assertEq(Env.load(pinned[i].network).network.centrifugeId, pinned[i].centrifugeId, pinned[i].network);
        }
    }

    /// @dev `Env.detect()` answers by chain id, so two configs claiming one chain would make which config a
    ///      run reads depend on directory order.
    function test_chainIdsAreUnique() public view {
        string[] memory names = _configNames();

        for (uint256 i; i < names.length; i++) {
            for (uint256 j = i + 1; j < names.length; j++) {
                assertTrue(
                    Env.load(names[i]).network.chainId != Env.load(names[j]).network.chainId,
                    string.concat(names[i], " and ", names[j], " claim the same chainId")
                );
            }
        }
    }

    function _pinnedIds() private pure returns (Pinned[] memory pinned) {
        pinned = new Pinned[](15);
        // Mainnets
        pinned[0] = Pinned("ethereum", 1);
        pinned[1] = Pinned("base", 2);
        pinned[2] = Pinned("arbitrum", 3);
        pinned[3] = Pinned("plume", 4);
        pinned[4] = Pinned("avalanche", 5);
        pinned[5] = Pinned("bnb-smart-chain", 6);
        pinned[6] = Pinned("hyper-evm", 9);
        pinned[7] = Pinned("optimism", 10);
        pinned[8] = Pinned("monad", 11);
        pinned[9] = Pinned("pharos", 12);
        pinned[10] = Pinned("x-layer", 13);
        // Testnets, which share the ids of the mainnets they stand in for
        pinned[11] = Pinned("sepolia", 1);
        pinned[12] = Pinned("base-sepolia", 2);
        pinned[13] = Pinned("arbitrum-sepolia", 3);
        pinned[14] = Pinned("hyper-evm-testnet", 9);
    }
}

/// @dev `Env.detect()` is what turns `--rpc-url <network>` into the config a deploy script reads, so a
///      mistake here does not fail — it silently deploys against another chain's addresses. Every config is
///      matched by its own chain id, which also covers the path filter: a manifest under env/latest/ or a
///      connections file mistaken for a config would answer the wrong name, or none at all.
contract EnvDetectTest is EnvFilesBase {
    function test_detectsEveryNetworkByChainId() public {
        string[] memory names = _configNames();

        for (uint256 i; i < names.length; i++) {
            EnvConfig memory config = Env.load(names[i]);
            vm.chainId(config.network.chainId);
            assertEq(Env.detect(), names[i], names[i]);
        }
    }

    function test_loadThroughDetectMatchesLoadByName() public {
        EnvConfig memory named = Env.load("sepolia");
        vm.chainId(named.network.chainId);
        EnvConfig memory detected = Env.load();

        assertEq(detected.network.name, named.network.name);
        assertEq(detected.network.centrifugeId, named.network.centrifugeId);
        assertEq(detected.contracts.root, named.contracts.root);
    }

    /// @dev env/anvil/<network>.json is written by script/deploy/anvil.sh and gitignored, so it is only here
    ///      on a machine that has run it. Detecting it is what proves depth-2 configs are reachable and that
    ///      the name keeps its directory.
    function test_detectsLocalForkConfigs() public {
        if (!vm.exists("env/anvil/sepolia.json")) return;

        vm.chainId(Env.load("anvil/sepolia").network.chainId);
        assertEq(Env.detect(), "anvil/sepolia");
    }

    function test_revertsOnAChainNoConfigNames() public {
        vm.chainId(123456789);
        vm.expectRevert(
            bytes(
                "No env config for chain 123456789: add env/<network>.json naming that chainId,"
                " and point --rpc-url at it"
            )
        );
        this.detect();
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function detect() external view returns (string memory) {
        return Env.detect();
    }
}

/// @dev `verifierUrl` (where source is submitted) and `explorerApiUrl` (where chain data is read) are two
///      different services on the Blockscout-family explorers. Conflating them is silent: the deploy scripts
///      records no block or transaction, and VerifyFactoryContracts reports every contract as unverified.
contract EnvExplorerUrlTest is Test {
    string constant ETHERSCAN_V2 = "https://api.etherscan.io/v2/api?chainid=";

    /// @dev Monad names a SocialScan endpoint that only accepts verification submissions, and Etherscan v2
    ///      does cover chain 143, so its reads go there instead of to the verifier.
    function test_monadReadsFromEtherscanNotItsVerifier() public view {
        EnvConfig memory config = Env.load("monad");

        assertEq(config.network.explorerApiUrl, string.concat(ETHERSCAN_V2, vm.toString(config.network.chainId)));
        assertTrue(keccak256(bytes(config.network.explorerApiUrl)) != keccak256(bytes(config.network.verifierUrl)));
    }

    /// @dev Plume is the opposite case: its Blockscout instance serves both, and it is not on Etherscan v2,
    ///      so the read URL has to be named explicitly rather than left to the default.
    function test_plumeReadsFromItsOwnExplorer() public view {
        EnvConfig memory config = Env.load("plume");
        assertEq(config.network.explorerApiUrl, "https://explorer.plume.org/api/");
    }

    /// @dev Every network without an explicit read URL falls back to Etherscan by chain id, never to the
    ///      verification endpoint
    function test_defaultsToEtherscanByChainId() public view {
        EnvConfig memory config = Env.load("ethereum");
        assertEq(config.network.explorerApiUrl, string.concat(ETHERSCAN_V2, vm.toString(config.network.chainId)));
    }
}

contract EnvConnectionsTest is Test {
    function test_mainnetConnectionsRequireDeployedAdapters() public view {
        _validateConnectionsHasDeployedAdapters("mainnet");
    }

    function test_testnetConnectionsRequireDeployedAdapters() public view {
        _validateConnectionsHasDeployedAdapters("testnet");
    }

    /// @dev An exception that outlives the drift it excuses is an exception nobody notices is there, so each
    ///      one has to still describe a real disagreement. This is what makes naming networks rather than
    ///      addresses safe: the entry stops being accepted when the drift is gone, not when it merely moves.
    function test_knownDriftIsStillDrift() public view {
        string[2][] memory entries = _knownDrift();

        for (uint256 e; e < entries.length; e++) {
            assertTrue(
                _disagreesWithAPeer(entries[e][0], entries[e][1]),
                string.concat(
                    entries[e][0], "'s ", entries[e][1], " adapter agrees with every peer now: drop this exception"
                )
            );
        }
    }

    function _validateConnectionsHasDeployedAdapters(string memory environment) private view {
        EnvConnectionsConfig memory connConfig = EnvConnections.load(environment);

        for (uint256 i; i < connConfig.networks.length; i++) {
            string memory networkName = connConfig.networks[i];
            EnvConfig memory chain1 = Env.load(networkName);
            Connection[] memory connections = chain1.network.connections();

            for (uint256 j; j < connections.length; j++) {
                EnvConfig memory chain2 = Env.load(connections[j].network);
                string memory pair = string.concat(networkName, " <-> ", connections[j].network);

                for (uint256 k; k < ADAPTERS; k++) {
                    if (!_uses(connections[j], k)) continue;

                    string memory adapter = _adapterName(k);
                    assertTrue(_deploys(chain1, k), _err(pair, adapter));
                    assertTrue(_deploys(chain2, k), _err(pair, adapter));

                    _assertSameAddress(pair, adapter, networkName, connections[j].network, chain1, chain2, k);
                }
            }
        }
    }

    /// @dev `AdapterActionBatcher` wires each remote peer in one pass, to the address its own adapter landed
    ///      on, which is only correct while CREATE3 keeps that address equal on both chains. A pair whose
    ///      configs disagree would wire to a well-formed address holding no contract, and nothing would fail:
    ///      the messages would simply never arrive. A side that has not been deployed yet records the zero
    ///      address and is skipped — there is nothing to disagree with until it is.
    function _assertSameAddress(
        string memory pair,
        string memory adapter,
        string memory network1,
        string memory network2,
        EnvConfig memory chain1,
        EnvConfig memory chain2,
        uint256 k
    ) private pure {
        address a = _adapterAddress(chain1, k);
        address b = _adapterAddress(chain2, k);

        if (a == address(0) || b == address(0)) return;
        if (_isKnownDrift(chain1.network.environment, network1, network2, adapter)) return;

        assertEq(a, b, string.concat(pair, ": ", adapter, " adapter is at a different address on each chain"));
    }

    /// @dev An adapter that is known to sit where the rest of its connections do not follow, named by network
    ///      and adapter rather than by the addresses involved. Addresses would describe the accident instead
    ///      of the fact: they stop matching as soon as either side is redeployed, which is when the pair is
    ///      *still* drifted and the quickest way to green is to paste the new pair in — an exception that
    ///      renews itself. A name holds until the drift is actually gone, and `test_knownDriftIsStillDrift`
    ///      is what then makes it go.
    ///
    ///      Today: hyper-evm-testnet's layerZero adapter was redeployed on its own, ~3.8M blocks after that
    ///      chain's protocol, through `DeployAdapters`, which salts with `msg.sender` rather than the gate.
    ///      A full testnet run puts every network back on one address and this entry can go.
    function _knownDrift() private pure returns (string[2][] memory entries) {
        entries = new string[2][](1);
        entries[0] = ["hyper-evm-testnet", "layerZero"];
    }

    /// @dev Mainnet is never excused: two chains carrying real value have no business disagreeing about
    ///      where a message arrives, and there is no testnet-style redeploy to explain it away.
    function _isKnownDrift(
        string memory environment,
        string memory network1,
        string memory network2,
        string memory adapter
    ) private pure returns (bool) {
        if (_eq(environment, "mainnet")) return false;

        string[2][] memory entries = _knownDrift();
        for (uint256 e; e < entries.length; e++) {
            if (!_eq(entries[e][1], adapter)) continue;
            if (_eq(entries[e][0], network1) || _eq(entries[e][0], network2)) return true;
        }
        return false;
    }

    /// @dev Whether the exception is still earning its place: the network's adapter differs from at least one
    ///      peer it is connected to through that adapter.
    function _disagreesWithAPeer(string memory network, string memory adapter) private view returns (bool) {
        EnvConfig memory config = Env.load(network);
        Connection[] memory connections = config.network.connections();

        for (uint256 k; k < ADAPTERS; k++) {
            if (!_eq(_adapterName(k), adapter)) continue;

            address own = _adapterAddress(config, k);
            for (uint256 j; j < connections.length; j++) {
                if (!_uses(connections[j], k)) continue;

                address peer = _adapterAddress(Env.load(connections[j].network), k);
                if (own != address(0) && peer != address(0) && own != peer) return true;
            }
        }
        return false;
    }

    function _err(string memory pair, string memory adapter) private pure returns (string memory) {
        return string.concat(pair, ": ", adapter, " not deployed in one of the chains");
    }

    // ---------------------------------------------------------------------------------------------------
    // The four adapters, by index, so the walk above is written once rather than once per adapter
    // ---------------------------------------------------------------------------------------------------

    uint256 private constant ADAPTERS = 4;

    function _adapterName(uint256 k) private pure returns (string memory) {
        if (k == 0) return "layerZero";
        if (k == 1) return "axelar";
        if (k == 2) return "chainlink";
        return "hyperlane";
    }

    function _uses(Connection memory connection, uint256 k) private pure returns (bool) {
        if (k == 0) return connection.layerZero;
        if (k == 1) return connection.axelar;
        if (k == 2) return connection.chainlink;
        return connection.hyperlane;
    }

    function _deploys(EnvConfig memory config, uint256 k) private pure returns (bool) {
        if (k == 0) return config.adapters.layerZero.deploy;
        if (k == 1) return config.adapters.axelar.deploy;
        if (k == 2) return config.adapters.chainlink.deploy;
        return config.adapters.hyperlane.deploy;
    }

    function _adapterAddress(EnvConfig memory config, uint256 k) private pure returns (address) {
        if (k == 0) return config.contracts.layerZeroAdapter;
        if (k == 1) return config.contracts.axelarAdapter;
        if (k == 2) return config.contracts.chainlinkAdapter;
        return config.contracts.hyperlaneAdapter;
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

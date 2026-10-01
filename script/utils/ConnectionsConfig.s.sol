// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Chains} from "./ChainConfig.s.sol";
import {StringSet, createStringSet} from "./StringSet.s.sol";

import "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

// The adapter names a connection rule may list, in `adapters` or `wiredOnly`
string constant LAYERZERO = "layerZero";
string constant AXELAR = "axelar";
string constant CHAINLINK = "chainlink";
string constant HYPERLANE = "hyperlane";

/// @dev `layerZero`, `axelar`, `chainlink` and `hyperlane` name the lane's global adapter set, which `threshold`
///      counts. The `*WiredOnly` flags name adapters wired to the lane but kept out of that set, for a pool to
///      include in its own. An adapter is one or the other, never both.
struct Connection {
    string network;
    bool layerZero;
    bool axelar;
    bool chainlink;
    bool hyperlane;
    uint8 threshold;
    bool layerZeroWiredOnly;
    bool axelarWiredOnly;
    bool chainlinkWiredOnly;
    bool hyperlaneWiredOnly;
}

struct ConnectionRuleJson {
    string[] left;
    string[] right;
    string[] adapters;
    uint256 threshold;
    string[] wiredOnly;
}

struct ConnectionsConfig {
    string[] networks;
    ConnectionRuleJson[] rules;
}

using ConnectionsConfigLib for ConnectionsConfig global;
using ConnectionLib for Connection global;

/// @notice Whether a lane wires an adapter at all, in its global set or wired only. Every reader that wires
///         asks this rather than combining the two flags itself, so the places that have to agree on it do.
library ConnectionLib {
    function wiresLayerZero(Connection memory connection) internal pure returns (bool) {
        return connection.layerZero || connection.layerZeroWiredOnly;
    }

    function wiresAxelar(Connection memory connection) internal pure returns (bool) {
        return connection.axelar || connection.axelarWiredOnly;
    }

    function wiresChainlink(Connection memory connection) internal pure returns (bool) {
        return connection.chainlink || connection.chainlinkWiredOnly;
    }

    function wiresHyperlane(Connection memory connection) internal pure returns (bool) {
        return connection.hyperlane || connection.hyperlaneWiredOnly;
    }
}

/// @notice loads an env/<environment>/connections.json file
library EnvConnections {
    function load(string memory environment) internal view returns (ConnectionsConfig memory config) {
        return parse(vm.readFile(Chains.connectionsPathOf(environment)));
    }

    /// @notice Same, from JSON already read
    function parse(string memory json) internal view returns (ConnectionsConfig memory config) {
        uint256 ruleCount;
        while (vm.keyExistsJson(json, string.concat(".connections[", vm.toString(ruleCount), "]"))) {
            ruleCount++;
        }

        config.rules = new ConnectionRuleJson[](ruleCount);
        for (uint256 i; i < ruleCount; i++) {
            string memory prefix = string.concat(".connections[", vm.toString(i), "]");
            config.rules[i].left = _parseSide(json, string.concat(prefix, ".chains[0]"));
            config.rules[i].right = _parseSide(json, string.concat(prefix, ".chains[1]"));
            config.rules[i].adapters = vm.parseJsonStringArray(json, string.concat(prefix, ".adapters"));
            config.rules[i].threshold = vm.parseJsonUint(json, string.concat(prefix, ".threshold"));
            // Optional: adapters wired to the rule's lanes but kept out of their global set
            if (vm.keyExistsJson(json, string.concat(prefix, ".wiredOnly"))) {
                config.rules[i].wiredOnly = vm.parseJsonStringArray(json, string.concat(prefix, ".wiredOnly"));
            }
            _validateRule(json, prefix, config.rules[i], i);
        }

        config.networks = _collectNetworks(config.rules);
    }

    /// @dev What a rule must hold, refused rather than resolved when it does not:
    ///      - only the keys this reader knows: a misspelled `wiredOnly` would otherwise drop the list unread
    ///      - only known adapter names, none in both lists: a misspelled one would simply not be wired
    ///      - a global set wherever an adapter is wired only: a pool's first `SetPoolAdapters` travels over
    ///        the lane's global set, so without one no pool could ever take a wired-only adapter up
    ///      - a threshold the set can meet, and none on an empty set
    function _validateRule(string memory json, string memory prefix, ConnectionRuleJson memory rule, uint256 index)
        private
        pure
    {
        string memory at = string.concat("connections[", vm.toString(index), "]: ");

        string[] memory keys = vm.parseJsonKeys(json, prefix);
        for (uint256 i; i < keys.length; i++) {
            bytes32 key = keccak256(bytes(keys[i]));
            require(
                key == keccak256("chains") || key == keccak256("adapters") || key == keccak256("threshold")
                    || key == keccak256("wiredOnly"),
                string.concat(at, "unknown key ", keys[i])
            );
        }

        for (uint256 i; i < rule.adapters.length; i++) {
            require(_isAdapter(rule.adapters[i]), string.concat(at, "unknown adapter ", rule.adapters[i]));
        }
        for (uint256 i; i < rule.wiredOnly.length; i++) {
            require(_isAdapter(rule.wiredOnly[i]), string.concat(at, "unknown adapter ", rule.wiredOnly[i]));
            for (uint256 j; j < rule.adapters.length; j++) {
                require(
                    keccak256(bytes(rule.wiredOnly[i])) != keccak256(bytes(rule.adapters[j])),
                    string.concat(at, rule.wiredOnly[i], " is both in the adapter set and wired only")
                );
            }
        }

        require(
            rule.wiredOnly.length == 0 || rule.adapters.length != 0,
            string.concat(at, "wired-only adapters need a global set to be taken up over")
        );
        require(rule.adapters.length != 0 || rule.threshold == 0, string.concat(at, "threshold without an adapter set"));
        require(rule.threshold <= rule.adapters.length, string.concat(at, "threshold above the adapter set"));
    }

    function _isAdapter(string memory name) private pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        return h == keccak256(bytes(LAYERZERO)) || h == keccak256(bytes(AXELAR)) || h == keccak256(bytes(CHAINLINK))
            || h == keccak256(bytes(HYPERLANE));
    }

    /// @dev Parses a side value that can be either a string (alias or literal) or an array of strings.
    function _parseSide(string memory json, string memory path) private view returns (string[] memory) {
        // Check if value is an array by testing for the first element
        if (vm.keyExistsJson(json, string.concat(path, "[0]"))) {
            return vm.parseJsonStringArray(json, path);
        }

        // It's a string — either an alias reference or a literal network name
        string memory value = vm.parseJsonString(json, path);
        string memory aliasPath = string.concat(".aliases.", value);
        if (vm.keyExistsJson(json, aliasPath)) {
            return vm.parseJsonStringArray(json, aliasPath);
        }

        // Literal network name — wrap in single-element array
        string[] memory result = new string[](1);
        result[0] = value;
        return result;
    }

    /// @dev Collects the unique set of networks from all resolved rule sides.
    function _collectNetworks(ConnectionRuleJson[] memory rules) private pure returns (string[] memory) {
        uint256 maxNames;
        for (uint256 i; i < rules.length; i++) {
            maxNames += rules[i].left.length + rules[i].right.length;
        }

        StringSet memory networks = createStringSet(maxNames);
        for (uint256 i; i < rules.length; i++) {
            networks.addAll(rules[i].left);
            networks.addAll(rules[i].right);
        }
        return networks.values();
    }
}

library ConnectionsConfigLib {
    function connectionsWith(ConnectionsConfig memory config, string memory network)
        internal
        pure
        returns (Connection[] memory connections)
    {
        // Count matches first: a lane exists when its rule names any adapter
        uint256 count;
        for (uint256 i; i < config.networks.length; i++) {
            if (_strEq(config.networks[i], network)) continue;
            ConnectionRuleJson memory rule = _findMatchingRule(config.rules, network, config.networks[i]);
            if (rule.adapters.length > 0 || rule.wiredOnly.length > 0) count++;
        }

        connections = new Connection[](count);
        uint256 idx;
        for (uint256 i; i < config.networks.length; i++) {
            if (_strEq(config.networks[i], network)) continue;
            ConnectionRuleJson memory rule = _findMatchingRule(config.rules, network, config.networks[i]);
            if (rule.adapters.length > 0 || rule.wiredOnly.length > 0) {
                connections[idx++] = Connection({
                    network: config.networks[i],
                    layerZero: _arrayContains(rule.adapters, LAYERZERO),
                    axelar: _arrayContains(rule.adapters, AXELAR),
                    chainlink: _arrayContains(rule.adapters, CHAINLINK),
                    hyperlane: _arrayContains(rule.adapters, HYPERLANE),
                    threshold: uint8(rule.threshold),
                    layerZeroWiredOnly: _arrayContains(rule.wiredOnly, LAYERZERO),
                    axelarWiredOnly: _arrayContains(rule.wiredOnly, AXELAR),
                    chainlinkWiredOnly: _arrayContains(rule.wiredOnly, CHAINLINK),
                    hyperlaneWiredOnly: _arrayContains(rule.wiredOnly, HYPERLANE)
                });
            }
        }
    }

    /// @dev The last matching rule (last match wins); an empty rule where none matches.
    function _findMatchingRule(ConnectionRuleJson[] memory rules, string memory a, string memory b)
        private
        pure
        returns (ConnectionRuleJson memory rule)
    {
        for (uint256 i = rules.length; i > 0; i--) {
            if (_matches(rules[i - 1], a, b)) return rules[i - 1];
        }
    }

    function _matches(ConnectionRuleJson memory rule, string memory a, string memory b) private pure returns (bool) {
        return (_arrayContains(rule.left, a) && _arrayContains(rule.right, b))
            || (_arrayContains(rule.left, b) && _arrayContains(rule.right, a));
    }

    function _arrayContains(string[] memory arr, string memory value) private pure returns (bool) {
        for (uint256 i; i < arr.length; i++) {
            if (_strEq(arr[i], value)) return true;
        }
        return false;
    }

    function _strEq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

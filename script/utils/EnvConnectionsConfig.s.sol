// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StringSet, createStringSet} from "./StringSet.s.sol";

import "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

struct Connection {
    string network;
    bool layerZero;
    bool wormhole;
    bool axelar;
    bool chainlink;
    uint8 threshold;
}

struct ConnectionRuleJson {
    string[] left;
    string[] right;
    string[] adapters;
    uint256 threshold;
}

struct EnvConnectionsConfig {
    string[] networks;
    ConnectionRuleJson[] rules;
}

using EnvConnectionsConfigLib for EnvConnectionsConfig global;

/// @notice loads an env/connections/<environment>.json file
library EnvConnections {
    function load(string memory environment) public view returns (EnvConnectionsConfig memory config) {
        string memory json = vm.readFile(string.concat("env/connections/", environment, ".json"));

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
        }

        config.networks = _collectNetworks(config.rules);
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

library EnvConnectionsConfigLib {
    function connectionsWith(EnvConnectionsConfig memory config, string memory network)
        internal
        pure
        returns (Connection[] memory connections)
    {
        // Count matches first
        uint256 count;
        for (uint256 i; i < config.networks.length; i++) {
            if (_strEq(config.networks[i], network)) continue;
            (string[] memory adapters,) = _findMatchingRule(config.rules, network, config.networks[i]);
            if (adapters.length > 0) count++;
        }

        connections = new Connection[](count);
        uint256 idx;
        for (uint256 i; i < config.networks.length; i++) {
            if (_strEq(config.networks[i], network)) continue;
            (string[] memory adapters, uint256 threshold) = _findMatchingRule(config.rules, network, config.networks[i]);
            if (adapters.length > 0) {
                connections[idx++] = Connection({
                    network: config.networks[i],
                    layerZero: _arrayContains(adapters, "layerZero"),
                    wormhole: _arrayContains(adapters, "wormhole"),
                    axelar: _arrayContains(adapters, "axelar"),
                    chainlink: _arrayContains(adapters, "chainlink"),
                    threshold: uint8(threshold)
                });
            }
        }
    }

    /// @dev Returns the adapters and threshold from the last matching rule (last match wins).
    function _findMatchingRule(ConnectionRuleJson[] memory rules, string memory a, string memory b)
        private
        pure
        returns (string[] memory adapters, uint256 threshold)
    {
        for (uint256 i = rules.length; i > 0; i--) {
            if (_matches(rules[i - 1], a, b)) {
                adapters = rules[i - 1].adapters;
                threshold = rules[i - 1].threshold;
                return (adapters, threshold);
            }
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

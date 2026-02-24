// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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

/// @notice loads an env/<network>.json file
library EnvConnections {
    function load(string memory environment) public view returns (EnvConnectionsConfig memory config) {
        string memory json = vm.readFile(string.concat("env/connections/", environment, ".json"));
        config.networks = _collectNetworks(json);

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
    }

    /// @dev Collects the unique set of networks from all alias values.
    function _collectNetworks(string memory json) private pure returns (string[] memory) {
        string[] memory aliasKeys = vm.parseJsonKeys(json, ".aliases");

        // Upper bound: sum of all alias array lengths
        uint256 maxNames;
        string[] memory aliasPath = new string[](aliasKeys.length);
        for (uint256 i; i < aliasKeys.length; i++) {
            aliasPath[i] = string.concat(".aliases.", aliasKeys[i]);
            string[] memory values = vm.parseJsonStringArray(json, aliasPath[i]);
            maxNames += values.length;
        }

        string[] memory buf = new string[](maxNames);
        uint256 count;
        for (uint256 i; i < aliasKeys.length; i++) {
            string[] memory values = vm.parseJsonStringArray(json, aliasPath[i]);
            for (uint256 j; j < values.length; j++) {
                bool found;
                for (uint256 k; k < count; k++) {
                    if (keccak256(bytes(buf[k])) == keccak256(bytes(values[j]))) {
                        found = true;
                        break;
                    }
                }
                if (!found) buf[count++] = values[j];
            }
        }

        // Trim to actual size
        string[] memory result = new string[](count);
        for (uint256 i; i < count; i++) {
            result[i] = buf[i];
        }
        return result;
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
                    layerZero: _includesAdapter(adapters, "layerZero"),
                    wormhole: _includesAdapter(adapters, "wormhole"),
                    axelar: _includesAdapter(adapters, "axelar"),
                    chainlink: _includesAdapter(adapters, "chainlink"),
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
        return (_matchesSide(rule.left, a) && _matchesSide(rule.right, b))
            || (_matchesSide(rule.left, b) && _matchesSide(rule.right, a));
    }

    function _matchesSide(string[] memory side, string memory name) private pure returns (bool) {
        for (uint256 i; i < side.length; i++) {
            if (_strEq(side[i], name)) return true;
        }
        return false;
    }

    function _includesAdapter(string[] memory adapters, string memory name) private pure returns (bool) {
        for (uint256 i; i < adapters.length; i++) {
            if (_strEq(adapters[i], name)) return true;
        }
        return false;
    }

    function _strEq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

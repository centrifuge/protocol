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
    string left;
    string right;
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
        config.networks = vm.parseJsonStringArray(json, ".networks");

        uint256 ruleCount;
        while (vm.keyExistsJson(json, string.concat(".connections[", vm.toString(ruleCount), "]"))) {
            ruleCount++;
        }

        config.rules = new ConnectionRuleJson[](ruleCount);
        for (uint256 i; i < ruleCount; i++) {
            string memory prefix = string.concat(".connections[", vm.toString(i), "]");
            config.rules[i].left = vm.parseJsonString(json, string.concat(prefix, ".chains.left"));
            config.rules[i].right = vm.parseJsonString(json, string.concat(prefix, ".chains.right"));
            config.rules[i].adapters = vm.parseJsonStringArray(json, string.concat(prefix, ".adapters"));
            config.rules[i].threshold = vm.parseJsonUint(json, string.concat(prefix, ".threshold"));
        }
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
        for (uint256 i; i < rules.length; i++) {
            if (_matches(rules[i], a, b)) {
                adapters = rules[i].adapters;
                threshold = rules[i].threshold;
            }
        }
    }

    function _matches(ConnectionRuleJson memory rule, string memory a, string memory b) private pure returns (bool) {
        return (_matchesSide(rule.left, a) && _matchesSide(rule.right, b))
            || (_matchesSide(rule.left, b) && _matchesSide(rule.right, a));
    }

    function _matchesSide(string memory side, string memory name) private pure returns (bool) {
        return _strEq(side, "ALL") || _strEq(side, name);
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

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @title CacheStore
/// @notice File-based key-value cache with cross-script persistence
/// @dev Enables data sharing between separate script executions (e.g., PRE and POST validation)
contract CacheStore {
    string internal _cacheDir;

    constructor(string memory cacheDir) {
        _cacheDir = cacheDir;
    }

    /// @notice Clean existing cache and create fresh directory
    function cleanAndCreateCacheDir() public {
        if (vm.exists(_cacheDir)) {
            vm.removeDir(_cacheDir, true);
        }
        vm.createDir(_cacheDir, true);
    }

    /// @notice Store a JSON value, persisted to file for cross-script access
    /// @param q Key string (used to derive the cache filename)
    /// @param json JSON string to store
    function set(string memory q, string memory json) public {
        // Persist to file for cross-script access
        vm.writeFile(_cacheFile(q), json);
    }

    /// @notice Retrieve a previously stored value from the file cache
    /// @param q Key string (same as used in set())
    /// @return json Stored JSON string
    function get(string memory q) public returns (string memory json) {
        string memory file = _cacheFile(q);
        require(vm.exists(file), "CacheStore: cache miss");
        json = vm.readFile(file);
        return json;
    }

    /// @notice Check if a key exists in cache
    /// @param q Key string
    function has(string memory q) public returns (bool) {
        return vm.exists(_cacheFile(q));
    }

    /// @dev Extracts first word from key for readable filenames
    /// @dev e.g. "outstandingInvests(limit: 1000) {...}" -> "outstandingInvests"
    function _extractQueryName(string memory q) internal pure returns (string memory) {
        bytes memory b = bytes(q);
        uint256 end = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "(" || b[i] == "{" || b[i] == " ") {
                end = i;
                break;
            }
        }
        if (end == 0) end = b.length;

        bytes memory name = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            name[i] = b[i];
        }
        return string(name);
    }

    /// @dev Uses key name + hash suffix to prevent collisions
    function _cacheFile(string memory q) internal view returns (string memory) {
        bytes32 hash = keccak256(bytes(q));
        return string.concat(_cacheDir, "/", _extractQueryName(q), "_", vm.toString(bytes4(hash)), ".json");
    }
}

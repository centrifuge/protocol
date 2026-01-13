// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {GraphQLQuery} from "../../../../script/utils/GraphQLQuery.s.sol";

import {Vm} from "forge-std/Vm.sol";

/// @title GraphQLStore
/// @notice Storage layer for GraphQL query results with optional file persistence
/// @dev PRE phase: query() executes and stores results (in memory + optionally to files)
/// @dev POST phase: get() retrieves stored results for comparison against v3.1 on-chain data
/// @dev File persistence enables cross-script communication in production migrations
contract GraphQLStore is GraphQLQuery {
    mapping(bytes32 => string) internal _stored;
    string internal _api;
    string internal _cacheDir;
    bool internal _useFiles;

    /// @param api GraphQL API endpoint
    /// @param cacheDir Cache directory path (empty string = in-memory only)
    /// @param cleanCache If true, wipe existing cache dir (use true for PRE, false for POST)
    constructor(string memory api, string memory cacheDir, bool cleanCache) {
        _api = api;
        _cacheDir = cacheDir;
        _useFiles = bytes(cacheDir).length > 0;

        if (_useFiles && cleanCache) {
            _cleanAndCreateCacheDir();
        }
    }

    function _graphQLApi() internal view override returns (string memory) {
        return _api;
    }

    /// @notice Clean existing cache and create fresh directory
    function _cleanAndCreateCacheDir() internal {
        Vm vmInst = _vmInstance();
        if (vmInst.exists(_cacheDir)) {
            vmInst.removeDir(_cacheDir, true);
        }
        vmInst.createDir(_cacheDir, true);
    }

    /// @notice Execute a GraphQL query and store result
    /// @dev Use in PRE phase - executes query, stores in memory and optionally to file
    /// @param q GraphQL query string (without outer JSON wrapper)
    /// @return json JSON response as string
    function query(string memory q) public returns (string memory json) {
        bytes32 key = keccak256(bytes(q));

        // Check memory cache first
        if (bytes(_stored[key]).length > 0) {
            return _stored[key];
        }

        // Check file cache (for resumed sessions)
        if (_useFiles) {
            string memory file = _cacheFile(q);
            if (_vmInstance().exists(file)) {
                json = _vmInstance().readFile(file);
                _stored[key] = json;
                return json;
            }
        }

        json = _queryGraphQL(q);
        _stored[key] = json;

        // Persist to file for cross-script access
        if (_useFiles) {
            _vmInstance().writeFile(_cacheFile(q), json);
        }

        return json;
    }

    /// @notice Set a custom json value
    /// @dev Use in PRE phase - set value, stores in memory and optionally to file
    /// @param q Any query used as key
    /// @param json JSON response as string
    function set(string memory q, string memory json) public {
        bytes32 key = keccak256(bytes(q));

        _stored[key] = json;

        // Persist to file for cross-script access
        if (_useFiles) {
            _vmInstance().writeFile(_cacheFile(q), json);
        }
    }

    /// @notice Retrieve previously stored query result
    /// @dev Use in POST phase - retrieves from memory or file cache
    /// @param q GraphQL query string (same as used in query())
    /// @return json Stored JSON response
    function get(string memory q) public returns (string memory json) {
        bytes32 key = keccak256(bytes(q));

        // Check memory first
        if (bytes(_stored[key]).length > 0) {
            return _stored[key];
        }

        // Check file (for cross-script persistence)
        if (_useFiles) {
            string memory file = _cacheFile(q);
            require(_vmInstance().exists(file), "GraphQLStore: cache miss - was PRE validation run?");
            json = _vmInstance().readFile(file);
            _stored[key] = json;
            return json;
        }

        revert("GraphQLStore: no cached data for query");
    }

    /// @notice Check if a query result is stored
    /// @param q GraphQL query string
    /// @return true if result is stored (in memory or file)
    function has(string memory q) public returns (bool) {
        bytes32 key = keccak256(bytes(q));

        if (bytes(_stored[key]).length > 0) {
            return true;
        }

        if (_useFiles) {
            return _vmInstance().exists(_cacheFile(q));
        }

        return false;
    }

    /// @notice Extract query name from query string for readable filenames
    /// @dev "outstandingInvests(limit: 1000) {...}" -> "outstandingInvests"
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

    /// @notice Build cache file path from query
    /// @dev Uses query name + hash suffix to prevent collisions between queries with same name but different params
    function _cacheFile(string memory q) internal view returns (string memory) {
        bytes32 hash = keccak256(bytes(q));
        return string.concat(_cacheDir, "/", _extractQueryName(q), "_", _vmInstance().toString(bytes4(hash)), ".json");
    }

    /// @notice Get Vm instance for cheatcodes
    function _vmInstance() internal pure returns (Vm) {
        return Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    }
}

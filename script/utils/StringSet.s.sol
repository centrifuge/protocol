// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Memory-based set of unique strings. Allocate with `create(maxSize)`,
///         then use `add`/`addAll` to insert and `values()` to get the trimmed result.
struct StringSet {
    string[] _buf;
    uint256 _count;
}

using StringSetLib for StringSet global;

/// @dev Creates a new StringSet pre-allocated for up to `maxSize` elements.
function createStringSet(uint256 maxSize) pure returns (StringSet memory set) {
    set._buf = new string[](maxSize);
}

library StringSetLib {
    function add(StringSet memory set, string memory value) internal pure {
        if (!contains(set, value)) {
            set._buf[set._count++] = value;
        }
    }

    function addAll(StringSet memory set, string[] memory values_) internal pure {
        for (uint256 i; i < values_.length; i++) {
            add(set, values_[i]);
        }
    }

    function contains(StringSet memory set, string memory value) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(value));
        for (uint256 i; i < set._count; i++) {
            if (keccak256(bytes(set._buf[i])) == h) return true;
        }
        return false;
    }

    function values(StringSet memory set) internal pure returns (string[] memory result) {
        result = new string[](set._count);
        for (uint256 i; i < set._count; i++) {
            result[i] = set._buf[i];
        }
    }
}


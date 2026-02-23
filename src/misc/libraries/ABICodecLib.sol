// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BytesLib} from "./BytesLib.sol";

/// @notice Describes ABI-encoded types as recursive trees.
///         Static = any 32-byte value (uint, address, bool, bytesN),
///         Dynamic = variable-length data (0 children = raw bytes/string, 1 child = element type of array),
///         Composite = tuple or struct, one child per field.
enum Type {
    Static,
    Dynamic,
    Composite
}

/// @notice Describes the shape of an ABI-encoded value as a recursive tree.
/// @dev    Example: `supply(address asset, uint256 amount, Params params)`
///         where `Params` is `struct { address receiver; uint16 code }`:
///
///         Composite ─┬─ Static      [0] address asset
///                    ├─ Static      [1] uint256 amount
///                    └─ Composite ──┬── [2] Params
///                                   ├─ Static [2,0] address receiver
///                                   └─ Static [2,1] uint16 code
struct Tree {
    Type t;
    Tree[] children;
}

/// @notice Whether this type is ABI-encoded via an offset pointer (Dynamic, or Composite containing any Dynamic).
function isDynamic(Tree memory tree) pure returns (bool) {
    if (tree.t == Type.Dynamic) return true;
    if (tree.t == Type.Composite) {
        for (uint256 i; i < tree.children.length; i++) {
            if (tree.children[i].isDynamic()) return true;
        }
    }
    return false;
}

/// @notice Total byte size of a static type (Static or all-static Composite).
function staticSize(Tree memory tree) pure returns (uint256) {
    if (tree.t == Type.Static) return 32;
    uint256 size;
    for (uint256 i; i < tree.children.length; i++) {
        size += tree.children[i].staticSize();
    }
    return size;
}

/// @notice Serialize a Tree to compact bytes (prefix-order). Each node is 2+ bytes:
///         [type: 1 byte] [childCount: 1 byte] [child₀ bytes] [child₁ bytes]...
/// @dev    Example: `deposit(uint256 amount, address receiver)` → Composite(Static, Static):
///         0x02 0x02 0x00 0x00 0x00 0x00
///         ──┬─ ──┬─ ──┬─ ──┬─ ──┬─ ──┬─
///      Composite 2  Static 0  Static 0
function encodeTree(Tree memory tree) pure returns (bytes memory) {
    bytes memory result = abi.encodePacked(uint8(tree.t), uint8(tree.children.length));
    for (uint256 i; i < tree.children.length; i++) {
        result = bytes.concat(result, tree.children[i].encodeTree());
    }
    return result;
}

using {isDynamic, staticSize, encodeTree} for Tree global;

/// @notice Deserialize a Tree from bytes.
function decodeTree(bytes memory data) pure returns (Tree memory) {
    (Tree memory tree,) = _decodeTreeAt(data, 0);
    return tree;
}

function _decodeTreeAt(bytes memory data, uint256 pos) pure returns (Tree memory, uint256) {
    Type t = Type(BytesLib.toUint8(data, pos));
    uint8 childCount = BytesLib.toUint8(data, pos + 1);
    pos += 2;

    Tree[] memory children = new Tree[](childCount);
    for (uint256 i; i < childCount; i++) {
        (children[i], pos) = _decodeTreeAt(data, pos);
    }
    return (Tree(t, children), pos);
}

struct Value {
    bytes data;
    Value[] children;
}

/// @title  ABICodecLib
/// @notice Generic ABI encoder/decoder using type trees and value trees.
///         A Tree describes the ABI type layout; a Value holds the decoded data.
///         Supports Static, Dynamic, and Composite types with arbitrary nesting.
library ABICodecLib {
    error OutOfBounds();

    //----------------------------------------------------------------------------------------------
    // Encode
    //----------------------------------------------------------------------------------------------

    /// @notice Encode a value tree into ABI-encoded bytes.
    function encode(Value memory value, Tree memory tree) internal pure returns (bytes memory) {
        if (tree.t == Type.Static) {
            return value.data;
        }

        // Dynamic with 0 children = raw bytes/string
        if (tree.t == Type.Dynamic && tree.children.length == 0) {
            uint256 padLen = BytesLib.align32(value.data.length) - value.data.length;
            return bytes.concat(abi.encode(value.data.length), value.data, new bytes(padLen));
        }

        // Dynamic array or Composite — both have ordered children
        bytes memory body = _encodeFields(value.children, tree);
        return tree.t == Type.Dynamic ? bytes.concat(abi.encode(value.children.length), body) : body;
    }

    /// @dev Encode ordered fields into head (static values / offsets) and tail (dynamic values).
    function _encodeFields(Value[] memory values, Tree memory tree) private pure returns (bytes memory) {
        uint256 n = values.length;

        // Calculate head size
        uint256 headSize;
        for (uint256 i; i < n; i++) {
            Tree memory child = _childTree(tree, i);
            headSize += child.isDynamic() ? 32 : child.staticSize();
        }

        // Encode children and build head + tail in one pass
        bytes memory head;
        bytes memory tail;
        uint256 tailOffset = headSize;

        for (uint256 i; i < n; i++) {
            Tree memory child = _childTree(tree, i);
            bytes memory part = encode(values[i], child);
            if (child.isDynamic()) {
                head = bytes.concat(head, abi.encode(tailOffset));
                tail = bytes.concat(tail, part);
                tailOffset += part.length;
            } else {
                head = bytes.concat(head, part);
            }
        }

        return bytes.concat(head, tail);
    }

    //----------------------------------------------------------------------------------------------
    // Decode
    //----------------------------------------------------------------------------------------------

    /// @notice Decode ABI-encoded bytes into a value tree.
    function decode(bytes memory data, Tree memory tree) internal pure returns (Value memory) {
        return _decodeAt(data, 0, tree);
    }

    /// @dev Decode a single value at the given byte offset.
    function _decodeAt(bytes memory data, uint256 base, Tree memory tree) private pure returns (Value memory) {
        if (tree.t == Type.Static) {
            return Value(BytesLib.slice(data, base, 32), new Value[](0));
        }

        // Dynamic with 0 children = raw bytes/string
        if (tree.t == Type.Dynamic && tree.children.length == 0) {
            uint256 len = BytesLib.toUint256(data, base);
            return Value(BytesLib.slice(data, base + 32, len), new Value[](0));
        }

        // Dynamic array or Composite — both have ordered children
        uint256 n = tree.t == Type.Dynamic ? BytesLib.toUint256(data, base) : tree.children.length;
        uint256 fieldsBase = tree.t == Type.Dynamic ? base + 32 : base;
        return Value("", _decodeFields(data, fieldsBase, tree, n));
    }

    /// @dev Decode sequential fields, resolving offsets for dynamic children.
    function _decodeFields(bytes memory data, uint256 base, Tree memory tree, uint256 n)
        private
        pure
        returns (Value[] memory)
    {
        Value[] memory values = new Value[](n);
        uint256 headPos = base;

        for (uint256 i; i < n; i++) {
            Tree memory child = _childTree(tree, i);
            if (child.isDynamic()) {
                uint256 offset = BytesLib.toUint256(data, headPos);
                values[i] = _decodeAt(data, base + offset, child);
                headPos += 32;
            } else {
                values[i] = _decodeAt(data, headPos, child);
                headPos += child.staticSize();
            }
        }

        return values;
    }

    /// @dev Arrays (Dynamic with 1 child) repeat the same element type for every index.
    ///      Composites (structs, tuples) have a distinct type per field, so each index maps to its own child tree.
    function _childTree(Tree memory tree, uint256 i) private pure returns (Tree memory) {
        return tree.t == Type.Dynamic ? tree.children[0] : tree.children[i];
    }

    //----------------------------------------------------------------------------------------------
    // Traverse
    //----------------------------------------------------------------------------------------------

    /// @notice Navigate to a nested value by index path.
    function traverse(Value memory value, Tree memory tree, uint256[] memory path)
        internal
        pure
        returns (Value memory, Tree memory)
    {
        for (uint256 i; i < path.length; i++) {
            uint256 idx = path[i];
            require(idx < value.children.length, OutOfBounds());
            value = value.children[idx];
            tree = tree.t == Type.Dynamic ? tree.children[0] : tree.children[idx];
        }
        return (value, tree);
    }
}

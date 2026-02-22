// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ABICodecLib, Value, Type, Tree} from "../../../src/misc/libraries/ABICodecLib.sol";

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import "forge-std/Test.sol";

contract ABICodecLibTest is Test {
    // ─── Tree helpers ────────────────────────────────────────────────────

    function _static() internal pure returns (Tree memory) {
        return Tree(Type.Static, new Tree[](0));
    }

    function _dynamic() internal pure returns (Tree memory) {
        return Tree(Type.Dynamic, new Tree[](0));
    }

    function _dynamicArray(Tree memory elem) internal pure returns (Tree memory) {
        Tree[] memory c = new Tree[](1);
        c[0] = elem;
        return Tree(Type.Dynamic, c);
    }

    function _composite(Tree[] memory children) internal pure returns (Tree memory) {
        return Tree(Type.Composite, children);
    }

    function _composite1(Tree memory a) internal pure returns (Tree memory) {
        Tree[] memory c = new Tree[](1);
        c[0] = a;
        return _composite(c);
    }

    function _composite2(Tree memory a, Tree memory b) internal pure returns (Tree memory) {
        Tree[] memory c = new Tree[](2);
        c[0] = a;
        c[1] = b;
        return _composite(c);
    }

    function _composite3(Tree memory a, Tree memory b, Tree memory d) internal pure returns (Tree memory) {
        Tree[] memory c = new Tree[](3);
        c[0] = a;
        c[1] = b;
        c[2] = d;
        return _composite(c);
    }

    // ─── Value helpers ───────────────────────────────────────────────────

    function _wordVal(uint256 v) internal pure returns (Value memory) {
        return Value(abi.encode(v), new Value[](0));
    }

    function _addrVal(address v) internal pure returns (Value memory) {
        return Value(abi.encode(v), new Value[](0));
    }

    function _bytesVal(bytes memory v) internal pure returns (Value memory) {
        return Value(v, new Value[](0));
    }

    function _compositeVal(Value[] memory children) internal pure returns (Value memory) {
        return Value("", children);
    }

    function _path(uint256 a) internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = a;
    }

    function _path(uint256 a, uint256 b) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = a;
        p[1] = b;
    }
}

// ─── WORD ────────────────────────────────────────────────────────────────────

contract ABICodecLibWordTest is ABICodecLibTest {
    function testRoundTripWord() public pure {
        Tree memory tree = _composite1(_static());
        bytes memory encoded = abi.encode(uint256(42));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(decoded.children.length, 1);
        assertEq(abi.decode(decoded.children[0].data, (uint256)), 42);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testRoundTripAddress() public pure {
        Tree memory tree = _composite1(_static());
        address addr = address(0xdead);
        bytes memory encoded = abi.encode(addr);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(abi.decode(decoded.children[0].data, (address)), addr);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testRoundTripBool() public pure {
        Tree memory tree = _composite1(_static());
        bytes memory encoded = abi.encode(true);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(abi.decode(decoded.children[0].data, (bool)), true);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }
}

// ─── BYTES ───────────────────────────────────────────────────────────────────

contract ABICodecLibBytesTest is ABICodecLibTest {
    function testRoundTripBytes() public pure {
        Tree memory tree = _composite1(_dynamic());
        bytes memory payload = hex"deadbeef";
        bytes memory encoded = abi.encode(payload);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(keccak256(decoded.children[0].data), keccak256(payload));

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testRoundTripEmptyBytes() public pure {
        Tree memory tree = _composite1(_dynamic());
        bytes memory payload = "";
        bytes memory encoded = abi.encode(payload);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(decoded.children[0].data.length, 0);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testRoundTripLongBytes() public pure {
        Tree memory tree = _composite1(_dynamic());
        // 65 bytes — not aligned to 32
        bytes memory payload = new bytes(65);
        for (uint256 i; i < 65; i++) {
            payload[i] = bytes1(uint8(i));
        }
        bytes memory encoded = abi.encode(payload);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(keccak256(decoded.children[0].data), keccak256(payload));

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }
}

// ─── TUPLE ───────────────────────────────────────────────────────────────────

contract ABICodecLibTupleTest is ABICodecLibTest {
    function testRoundTripTupleOfWords() public pure {
        // (uint256, address)
        Tree memory tree = _composite2(_static(), _static());
        bytes memory encoded = abi.encode(uint256(100), address(0xBEEF));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(decoded.children.length, 2);
        assertEq(abi.decode(decoded.children[0].data, (uint256)), 100);
        assertEq(abi.decode(decoded.children[1].data, (address)), address(0xBEEF));

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testRoundTripTupleWithDynamic() public pure {
        // (uint256, bytes, address)
        Tree memory tree = _composite3(_static(), _dynamic(), _static());
        bytes memory encoded = abi.encode(uint256(7), hex"cafe", address(0x1234));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(abi.decode(decoded.children[0].data, (uint256)), 7);
        assertEq(keccak256(decoded.children[1].data), keccak256(hex"cafe"));
        assertEq(abi.decode(decoded.children[2].data, (address)), address(0x1234));

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testEmptyTuple() public pure {
        Tree memory tree = _composite(new Tree[](0));
        bytes memory encoded = "";

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(decoded.children.length, 0);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(reencoded.length, 0);
    }

    function testNestedTuple() public pure {
        // (uint256, (address, uint256))
        Tree memory inner = _composite2(_static(), _static());
        Tree memory tree = _composite2(_static(), inner);
        bytes memory encoded = abi.encode(uint256(1), address(0xABC), uint256(2));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(abi.decode(decoded.children[0].data, (uint256)), 1);
        assertEq(decoded.children[1].children.length, 2);
        assertEq(abi.decode(decoded.children[1].children[0].data, (address)), address(0xABC));
        assertEq(abi.decode(decoded.children[1].children[1].data, (uint256)), 2);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }
}

// ─── ARRAY ───────────────────────────────────────────────────────────────────

contract ABICodecLibArrayTest is ABICodecLibTest {
    function testRoundTripArrayOfWords() public pure {
        // uint256[]
        Tree memory tree = _composite1(_dynamicArray(_static()));
        uint256[] memory arr = new uint256[](3);
        arr[0] = 10;
        arr[1] = 20;
        arr[2] = 30;
        bytes memory encoded = abi.encode(arr);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        Value memory arrVal = decoded.children[0];
        assertEq(arrVal.children.length, 3);
        assertEq(abi.decode(arrVal.children[0].data, (uint256)), 10);
        assertEq(abi.decode(arrVal.children[1].data, (uint256)), 20);
        assertEq(abi.decode(arrVal.children[2].data, (uint256)), 30);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testEmptyArray() public pure {
        Tree memory tree = _composite1(_dynamicArray(_static()));
        uint256[] memory arr = new uint256[](0);
        bytes memory encoded = abi.encode(arr);

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertEq(decoded.children[0].children.length, 0);

        bytes memory reencoded = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reencoded), keccak256(encoded));
    }

    function testArrayOfTuples() public pure {
        // (address, uint256)[]
        Tree memory elemTree = _composite2(_static(), _static());
        Tree memory tree = _composite1(_dynamicArray(elemTree));

        // Build from values since abi.encode can't directly encode tuple arrays
        Value[] memory elems = new Value[](2);

        Value[] memory e0 = new Value[](2);
        e0[0] = _addrVal(address(0xA));
        e0[1] = _wordVal(100);
        elems[0] = _compositeVal(e0);

        Value[] memory e1 = new Value[](2);
        e1[0] = _addrVal(address(0xB));
        e1[1] = _wordVal(200);
        elems[1] = _compositeVal(e1);

        Value[] memory top = new Value[](1);
        top[0] = Value("", elems);
        Value memory root = _compositeVal(top);

        bytes memory enc = ABICodecLib.encode(root, tree);
        Value memory decoded = ABICodecLib.decode(enc, tree);

        Value memory arrVal = decoded.children[0];
        assertEq(arrVal.children.length, 2);
        assertEq(abi.decode(arrVal.children[0].children[0].data, (address)), address(0xA));
        assertEq(abi.decode(arrVal.children[0].children[1].data, (uint256)), 100);
        assertEq(abi.decode(arrVal.children[1].children[0].data, (address)), address(0xB));
        assertEq(abi.decode(arrVal.children[1].children[1].data, (uint256)), 200);

        // Verify re-encoding produces identical bytes
        bytes memory reenc = ABICodecLib.encode(decoded, tree);
        assertEq(keccak256(reenc), keccak256(enc));
    }
}

// ─── TRAVERSE ────────────────────────────────────────────────────────────────

contract ABICodecLibTraverseTest is ABICodecLibTest {
    function testTraverseTopLevel() public pure {
        // (uint256, address) — traverse to field 1
        Tree memory tree = _composite2(_static(), _static());
        bytes memory encoded = abi.encode(uint256(1), address(0xBEEF));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        (Value memory v, Tree memory t) = ABICodecLib.traverse(decoded, tree, _path(1));

        assertEq(abi.decode(v.data, (address)), address(0xBEEF));
        assertTrue(t.t == Type.Static);
    }

    function testTraverseNested() public pure {
        // (uint256, (address, uint256)) — traverse to [1, 0]
        Tree memory inner = _composite2(_static(), _static());
        Tree memory tree = _composite2(_static(), inner);
        bytes memory encoded = abi.encode(uint256(1), address(0xABC), uint256(2));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        (Value memory v,) = ABICodecLib.traverse(decoded, tree, _path(1, 0));

        assertEq(abi.decode(v.data, (address)), address(0xABC));
    }

    function testTraverseArray() public pure {
        // uint256[] — traverse to element at index 2
        Tree memory tree = _composite1(_dynamicArray(_static()));
        uint256[] memory arr = new uint256[](3);
        arr[0] = 10;
        arr[1] = 20;
        arr[2] = 30;
        bytes memory encoded = abi.encode(arr);

        Value memory decoded = ABICodecLib.decode(encoded, tree);

        // First traverse into the array (child 0 of the tuple), then element 2
        (Value memory v,) = ABICodecLib.traverse(decoded, tree, _path(0, 2));
        assertEq(abi.decode(v.data, (uint256)), 30);
    }

    function testTraverseEmptyPath() public pure {
        Tree memory tree = _composite1(_static());
        bytes memory encoded = abi.encode(uint256(42));

        Value memory decoded = ABICodecLib.decode(encoded, tree);
        uint256[] memory emptyPath = new uint256[](0);
        (Value memory v,) = ABICodecLib.traverse(decoded, tree, emptyPath);

        // Empty path returns the root value
        assertEq(v.children.length, 1);
    }

    function testTraverseOutOfBoundsReverts() public {
        TraverseHelper helper = new TraverseHelper();

        vm.expectRevert(ABICodecLib.OutOfBounds.selector);
        helper.traverseSingleWord(abi.encode(uint256(42)), 5);
    }
}

// ─── isDynamic ───────────────────────────────────────────────────────────────

contract ABICodecLibIsDynamicTest is ABICodecLibTest {
    function testWordIsStatic() public pure {
        assertFalse(_static().isDynamic());
    }

    function testBytesIsDynamic() public pure {
        assertTrue(_dynamic().isDynamic());
    }

    function testArrayIsDynamic() public pure {
        assertTrue(_dynamicArray(_static()).isDynamic());
    }

    function testStaticTupleIsStatic() public pure {
        assertFalse(_composite2(_static(), _static()).isDynamic());
    }

    function testDynamicTupleIsDynamic() public pure {
        assertTrue(_composite2(_static(), _dynamic()).isDynamic());
    }
}

// ─── FUZZ: ENCODE/DECODE ROUNDTRIP ──────────────────────────────────────────

contract ABICodecLibFuzzTest is ABICodecLibTest {
    uint256 constant MAX_DEPTH = 2;
    uint256 constant MAX_COMPOSITE_CHILDREN = 3;
    uint256 constant MAX_ARRAY_LEN = 3;
    uint256 constant MAX_BYTES_LEN = 65;

    // --- Deep value equality ---

    function _valueEq(Value memory a, Value memory b) internal pure returns (bool) {
        if (keccak256(a.data) != keccak256(b.data)) return false;
        if (a.children.length != b.children.length) return false;
        for (uint256 i; i < a.children.length; i++) {
            if (!_valueEq(a.children[i], b.children[i])) return false;
        }
        return true;
    }

    function _assertRoundtrip(Value memory value, Tree memory tree) internal pure {
        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);
        assertTrue(_valueEq(value, decoded));
        assertEq(keccak256(ABICodecLib.encode(decoded, tree)), keccak256(encoded));
    }

    // --- Pseudo-random helper ---

    function _rand(uint256 seed, uint256 n) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, n)));
    }

    // --- Tree generation ---

    function _genTree(uint256 seed, uint256 n, uint256 depth) internal pure returns (Tree memory, uint256) {
        uint256 typeChoice = _rand(seed, n) % 4;
        n++;

        if (depth >= MAX_DEPTH || typeChoice == 0) {
            return (Tree(Type.Static, new Tree[](0)), n);
        }

        if (typeChoice == 1) {
            return (Tree(Type.Dynamic, new Tree[](0)), n);
        }

        if (typeChoice == 2) {
            Tree memory elem;
            (elem, n) = _genTree(seed, n, depth + 1);
            Tree[] memory c = new Tree[](1);
            c[0] = elem;
            return (Tree(Type.Dynamic, c), n);
        }

        // Composite
        uint256 childCount = 1 + _rand(seed, n) % MAX_COMPOSITE_CHILDREN;
        n++;
        Tree[] memory children = new Tree[](childCount);
        for (uint256 i; i < childCount; i++) {
            (children[i], n) = _genTree(seed, n, depth + 1);
        }
        return (Tree(Type.Composite, children), n);
    }

    // --- Value generation ---

    function _genValue(uint256 seed, uint256 n, Tree memory tree) internal pure returns (Value memory, uint256) {
        if (tree.t == Type.Static) {
            return (Value(abi.encode(_rand(seed, n)), new Value[](0)), n + 1);
        }

        if (tree.t == Type.Dynamic && tree.children.length == 0) {
            uint256 len = _rand(seed, n) % (MAX_BYTES_LEN + 1);
            bytes32 fill = bytes32(_rand(seed, n + 1));
            bytes memory data = new bytes(len);
            for (uint256 i; i < len; i++) {
                if (i > 0 && i % 32 == 0) fill = keccak256(abi.encode(fill));
                data[i] = fill[i % 32];
            }
            return (Value(data, new Value[](0)), n + 2);
        }

        if (tree.t == Type.Dynamic) {
            uint256 arrLen = _rand(seed, n) % (MAX_ARRAY_LEN + 1);
            n++;
            Value[] memory children = new Value[](arrLen);
            for (uint256 i; i < arrLen; i++) {
                (children[i], n) = _genValue(seed, n, tree.children[0]);
            }
            return (Value("", children), n);
        }

        // Composite
        Value[] memory children = new Value[](tree.children.length);
        for (uint256 i; i < tree.children.length; i++) {
            (children[i], n) = _genValue(seed, n, tree.children[i]);
        }
        return (Value("", children), n);
    }

    // --- Fixed-shape fuzz tests ---

    function testFuzz_roundtrip_singleStatic(uint256 a) public pure {
        // f(uint256)
        Value[] memory c = new Value[](1);
        c[0] = _wordVal(a);
        _assertRoundtrip(_compositeVal(c), _composite1(_static()));
    }

    function testFuzz_roundtrip_twoStatic(uint256 a, address b) public pure {
        // f(uint256, address)
        Value[] memory c = new Value[](2);
        c[0] = _wordVal(a);
        c[1] = _addrVal(b);
        _assertRoundtrip(_compositeVal(c), _composite2(_static(), _static()));
    }

    function testFuzz_roundtrip_dynamicBytes(bytes calldata data) public pure {
        // f(bytes)
        Value[] memory c = new Value[](1);
        c[0] = _bytesVal(data);
        _assertRoundtrip(_compositeVal(c), _composite1(_dynamic()));
    }

    function testFuzz_roundtrip_staticDynamicStatic(uint256 a, bytes calldata data, uint256 b) public pure {
        // f(uint256, bytes, uint256) — dynamic field in the middle tests head/tail layout
        Value[] memory c = new Value[](3);
        c[0] = _wordVal(a);
        c[1] = _bytesVal(data);
        c[2] = _wordVal(b);
        _assertRoundtrip(_compositeVal(c), _composite3(_static(), _dynamic(), _static()));
    }

    function testFuzz_roundtrip_staticArray(uint256 seed) public pure {
        // f(uint256[])
        uint256 len = seed % 5;
        Value[] memory elems = new Value[](len);
        for (uint256 i; i < len; i++) {
            elems[i] = _wordVal(uint256(keccak256(abi.encode(seed, i))));
        }
        Value[] memory top = new Value[](1);
        top[0] = Value("", elems);
        _assertRoundtrip(_compositeVal(top), _composite1(_dynamicArray(_static())));
    }

    function testFuzz_roundtrip_nestedComposite(uint256 a, uint256 b, uint256 c_) public pure {
        // f(uint256, (uint256, uint256))
        Value[] memory innerC = new Value[](2);
        innerC[0] = _wordVal(b);
        innerC[1] = _wordVal(c_);
        Value[] memory outerC = new Value[](2);
        outerC[0] = _wordVal(a);
        outerC[1] = _compositeVal(innerC);

        Tree memory inner = _composite2(_static(), _static());
        _assertRoundtrip(_compositeVal(outerC), _composite2(_static(), inner));
    }

    function testFuzz_roundtrip_arrayOfDynamic(bytes calldata a, bytes calldata b) public pure {
        // f(bytes[])
        Value[] memory elems = new Value[](2);
        elems[0] = _bytesVal(a);
        elems[1] = _bytesVal(b);
        Value[] memory top = new Value[](1);
        top[0] = Value("", elems);
        _assertRoundtrip(_compositeVal(top), _composite1(_dynamicArray(_dynamic())));
    }

    // --- Generated tree + value roundtrip ---

    function testFuzz_roundtrip_generated(uint256 seed) public pure {
        uint256 n;
        Tree memory tree;
        (tree, n) = _genTree(seed, n, 0);
        Value memory value;
        (value, n) = _genValue(seed, n, tree);
        _assertRoundtrip(value, tree);
    }
}

// ─── HALMOS: FORMAL VERIFICATION OF ROUNDTRIP ───────────────────────────────

/// @dev Symbolic tests proving encode/decode roundtrip for ALL possible values within each tree shape.
///      Run with: halmos --match-contract ABICodecLibHalmosTest --loop 4
contract ABICodecLibHalmosTest is ABICodecLibTest, SymTest {
    // --- Composite of all-static fields ---

    /// @custom:halmos --loop 2
    function check_roundtrip_singleStatic(uint256 a) public pure {
        Tree memory tree = _composite1(_static());
        Value[] memory c = new Value[](1);
        c[0] = _wordVal(a);
        Value memory value = _compositeVal(c);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);

        assert(decoded.children.length == 1);
        assert(abi.decode(decoded.children[0].data, (uint256)) == a);
    }

    /// @custom:halmos --loop 3
    function check_roundtrip_twoStatic(uint256 a, uint256 b) public pure {
        Tree memory tree = _composite2(_static(), _static());
        Value[] memory c = new Value[](2);
        c[0] = _wordVal(a);
        c[1] = _wordVal(b);
        Value memory value = _compositeVal(c);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);

        assert(decoded.children.length == 2);
        assert(abi.decode(decoded.children[0].data, (uint256)) == a);
        assert(abi.decode(decoded.children[1].data, (uint256)) == b);
    }

    /// @custom:halmos --loop 4
    function check_roundtrip_threeStatic(uint256 a, uint256 b, uint256 c_) public pure {
        Tree memory tree = _composite3(_static(), _static(), _static());
        Value[] memory ch = new Value[](3);
        ch[0] = _wordVal(a);
        ch[1] = _wordVal(b);
        ch[2] = _wordVal(c_);
        Value memory value = _compositeVal(ch);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);

        assert(decoded.children.length == 3);
        assert(abi.decode(decoded.children[0].data, (uint256)) == a);
        assert(abi.decode(decoded.children[1].data, (uint256)) == b);
        assert(abi.decode(decoded.children[2].data, (uint256)) == c_);
    }

    // --- Nested static composite ---

    /// @custom:halmos --loop 3
    function check_roundtrip_nestedComposite(uint256 a, uint256 b, uint256 c_) public pure {
        // f(uint256, (uint256, uint256))
        Tree memory inner = _composite2(_static(), _static());
        Tree memory tree = _composite2(_static(), inner);

        Value[] memory innerC = new Value[](2);
        innerC[0] = _wordVal(b);
        innerC[1] = _wordVal(c_);
        Value[] memory outerC = new Value[](2);
        outerC[0] = _wordVal(a);
        outerC[1] = _compositeVal(innerC);
        Value memory value = _compositeVal(outerC);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);

        assert(decoded.children.length == 2);
        assert(abi.decode(decoded.children[0].data, (uint256)) == a);
        assert(decoded.children[1].children.length == 2);
        assert(abi.decode(decoded.children[1].children[0].data, (uint256)) == b);
        assert(abi.decode(decoded.children[1].children[1].data, (uint256)) == c_);
    }

    // --- Dynamic bytes (symbolic content, concrete length) ---

    /// @custom:halmos --loop 2
    function check_roundtrip_dynamicBytes32() public view {
        // f(bytes) with 32-byte payload — proves for ALL 2^256 possible 32-byte values
        Tree memory tree = _composite1(_dynamic());
        bytes memory data = svm.createBytes(32, "data");
        Value[] memory c = new Value[](1);
        c[0] = Value(data, new Value[](0));
        Value memory value = _compositeVal(c);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);
        bytes memory reencoded = ABICodecLib.encode(decoded, tree);

        assert(keccak256(reencoded) == keccak256(encoded));
    }

    /// @custom:halmos --loop 2
    function check_roundtrip_dynamicBytes7() public view {
        // f(bytes) with 7-byte payload — non-aligned, tests padding logic
        Tree memory tree = _composite1(_dynamic());
        bytes memory data = svm.createBytes(7, "data");
        Value[] memory c = new Value[](1);
        c[0] = Value(data, new Value[](0));
        Value memory value = _compositeVal(c);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);
        bytes memory reencoded = ABICodecLib.encode(decoded, tree);

        assert(keccak256(reencoded) == keccak256(encoded));
    }

    // --- Mixed static + dynamic ---

    /// @custom:halmos --loop 4
    function check_roundtrip_staticDynamicStatic(uint256 a, uint256 b) public view {
        // f(uint256, bytes, uint256) — dynamic field in the middle tests head/tail offset layout
        Tree memory tree = _composite3(_static(), _dynamic(), _static());
        bytes memory data = svm.createBytes(32, "data");
        Value[] memory c = new Value[](3);
        c[0] = _wordVal(a);
        c[1] = Value(data, new Value[](0));
        c[2] = _wordVal(b);
        Value memory value = _compositeVal(c);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);
        bytes memory reencoded = ABICodecLib.encode(decoded, tree);

        assert(keccak256(reencoded) == keccak256(encoded));
        assert(abi.decode(decoded.children[0].data, (uint256)) == a);
        assert(abi.decode(decoded.children[2].data, (uint256)) == b);
    }

    // --- Dynamic array with static elements ---

    /// @custom:halmos --loop 4
    function check_roundtrip_staticArray3(uint256 a, uint256 b, uint256 c_) public pure {
        // f(uint256[]) with 3 elements
        Tree memory tree = _composite1(_dynamicArray(_static()));
        Value[] memory elems = new Value[](3);
        elems[0] = _wordVal(a);
        elems[1] = _wordVal(b);
        elems[2] = _wordVal(c_);
        Value[] memory top = new Value[](1);
        top[0] = Value("", elems);
        Value memory value = _compositeVal(top);

        bytes memory encoded = ABICodecLib.encode(value, tree);
        Value memory decoded = ABICodecLib.decode(encoded, tree);

        assert(decoded.children[0].children.length == 3);
        assert(abi.decode(decoded.children[0].children[0].data, (uint256)) == a);
        assert(abi.decode(decoded.children[0].children[1].data, (uint256)) == b);
        assert(abi.decode(decoded.children[0].children[2].data, (uint256)) == c_);
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// @dev External wrapper so vm.expectRevert works (recursive structs can't cross external boundaries).
contract TraverseHelper {
    function traverseSingleWord(bytes memory data, uint256 idx) external pure {
        Tree[] memory c = new Tree[](1);
        c[0] = Tree(Type.Static, new Tree[](0));
        Tree memory tree = Tree(Type.Composite, c);
        Value memory decoded = ABICodecLib.decode(data, tree);
        uint256[] memory p = new uint256[](1);
        p[0] = idx;
        ABICodecLib.traverse(decoded, tree, p);
    }
}

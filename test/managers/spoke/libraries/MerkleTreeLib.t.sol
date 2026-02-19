// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MerkleTreeLib} from "./MerkleTreeLib.sol";

/// @title MerkleTreeLib Wrapper for testing reverts
/// @dev External wrapper to enable vm.expectRevert to work with internal library calls
contract MerkleTreeLibWrapper {
    function generateMerkleTree(bytes32[] memory inputLeafs) external pure returns (bytes32[][] memory tree) {
        return MerkleTreeLib.generateMerkleTree(inputLeafs);
    }

    function getProofsUsingTree(bytes32[] memory leafs, bytes32[][] memory tree)
        external
        pure
        returns (bytes32[][] memory proofs)
    {
        return MerkleTreeLib.getProofsUsingTree(leafs, tree);
    }
}

/// @title MerkleTreeLib Tests
/// @notice Tests for MerkleTreeLib bug fixes (Issue #574)
/// @dev Tests cover: odd leaf counts, empty input, single leaf, and proof verification
contract MerkleTreeLibTest is Test {
    MerkleTreeLibWrapper wrapper;

    function setUp() public {
        wrapper = new MerkleTreeLibWrapper();
    }

    // --- Helper Functions ---

    /// @dev Sorted-pair hashing (must match library semantics)
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Process a proof to compute the root
    function _processProof(bytes32 leaf, bytes32[] memory proof) internal pure returns (bytes32 h) {
        h = leaf;
        for (uint256 i; i < proof.length; ++i) {
            h = _hashPair(h, proof[i]);
        }
    }

    /// @dev Generate n unique leaves
    function _leaves(uint256 n) internal pure returns (bytes32[] memory L) {
        L = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            L[i] = keccak256(abi.encodePacked("leaf-", i));
        }
    }

    // --- Bug Fix #1: Odd leaf count in _buildTrees ---

    /// @notice Test that odd leaf counts build correctly (previously reverted with out-of-bounds)
    function test_OddLeafCount_BuildsSuccessfully() public pure {
        bytes32[] memory L = new bytes32[](3);
        L[0] = keccak256("A");
        L[1] = keccak256("B");
        L[2] = keccak256("C");

        // This should NOT revert after the fix
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);

        // Verify tree structure
        assertEq(tree[0].length, 3, "Layer 0 should have 3 leaves");
        assertGt(tree.length, 1, "Tree should have multiple layers");
    }

    /// @notice Test odd leaf count with 5 leaves and verify all proofs
    function test_OddLeafCount_ProofsVerify() public pure {
        bytes32[] memory L = _leaves(5);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);

        // Root is at last layer, index 0
        bytes32 root = tree[tree.length - 1][0];

        for (uint256 i; i < L.length; ++i) {
            bytes32[] memory single = new bytes32[](1);
            single[0] = L[i];
            bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);

            // One proof per query
            assertEq(proofs.length, 1, "Should have one proof");
            // Proof height should be tree height - 1
            assertEq(proofs[0].length, tree.length - 1, "Proof length should match tree height - 1");

            bytes32 computed = _processProof(L[i], proofs[0]);
            assertEq(computed, root, "Proof should verify to root");
        }
    }

    /// @notice Test odd leaf count with 7 leaves
    function test_OddLeafCount_SevenLeaves_ProofsVerify() public pure {
        bytes32[] memory L = _leaves(7);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        for (uint256 i; i < L.length; ++i) {
            bytes32[] memory single = new bytes32[](1);
            single[0] = L[i];
            bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);
            bytes32 computed = _processProof(L[i], proofs[0]);
            assertEq(computed, root, "Proof should verify to root");
        }
    }

    // --- Bug Fix #2: Odd-length layer in _generateProof ---

    /// @notice Test that proof generation works for last leaf in odd-length layer
    function test_ProofForLastLeafInOddLayer() public pure {
        bytes32[] memory L = new bytes32[](3);
        L[0] = keccak256("A");
        L[1] = keccak256("B");
        L[2] = keccak256("C");

        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        // Get proof for the LAST leaf (index 2) - this was the bug case
        bytes32[] memory single = new bytes32[](1);
        single[0] = L[2];
        bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);

        bytes32 computed = _processProof(L[2], proofs[0]);
        assertEq(computed, root, "Proof for last leaf should verify");
    }

    // --- Bug Fix #3: Empty input validation ---

    /// @notice Test that empty input reverts
    function test_EmptyInput_Reverts() public {
        bytes32[] memory L = new bytes32[](0);
        vm.expectRevert(MerkleTreeLib.NoLeaves.selector);
        wrapper.generateMerkleTree(L);
    }

    // --- Single leaf case ---

    /// @notice Test single leaf tree builds and proof verifies
    function test_SingleLeaf_BuildsAndVerifies() public pure {
        bytes32[] memory L = _leaves(1);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);

        // Expect 2 layers: [leaf], [root]
        assertEq(tree.length, 2, "Tree should have 2 layers");
        assertEq(tree[0].length, 1, "Layer 0 should have 1 leaf");
        assertEq(tree[1].length, 1, "Layer 1 should have 1 root");

        bytes32 root = tree[1][0];

        bytes32[] memory single = new bytes32[](1);
        single[0] = L[0];
        bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);

        assertEq(proofs.length, 1, "Should have one proof");
        assertEq(proofs[0].length, 1, "Proof should have one sibling (the leaf itself)");

        bytes32 computed = _processProof(L[0], proofs[0]);
        assertEq(computed, root, "Proof should verify to root");
    }

    // --- Even leaf counts (regression tests) ---

    /// @notice Test even leaf count with 8 leaves
    function test_EvenLeafCount_EightLeaves_ProofsVerify() public pure {
        bytes32[] memory L = _leaves(8);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        for (uint256 i; i < L.length; ++i) {
            bytes32[] memory single = new bytes32[](1);
            single[0] = L[i];
            bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);
            bytes32 computed = _processProof(L[i], proofs[0]);
            assertEq(computed, root, "Proof should verify to root");
        }
    }

    /// @notice Test even leaf count with 4 leaves
    function test_EvenLeafCount_FourLeaves_ProofsVerify() public pure {
        bytes32[] memory L = _leaves(4);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        for (uint256 i; i < L.length; ++i) {
            bytes32[] memory single = new bytes32[](1);
            single[0] = L[i];
            bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);
            bytes32 computed = _processProof(L[i], proofs[0]);
            assertEq(computed, root, "Proof should verify to root");
        }
    }

    /// @notice Test even leaf count with 2 leaves
    function test_EvenLeafCount_TwoLeaves_ProofsVerify() public pure {
        bytes32[] memory L = _leaves(2);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        for (uint256 i; i < L.length; ++i) {
            bytes32[] memory single = new bytes32[](1);
            single[0] = L[i];
            bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);
            bytes32 computed = _processProof(L[i], proofs[0]);
            assertEq(computed, root, "Proof should verify to root");
        }
    }

    // --- Bug Fix #6: Leaf not found detection ---

    /// @notice Test that requesting proof for non-existent leaf reverts
    function test_LeafNotFound_Reverts() public {
        bytes32[] memory L = _leaves(4);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);

        // Try to get proof for a leaf that doesn't exist
        bytes32[] memory fake = new bytes32[](1);
        fake[0] = keccak256("non-existent-leaf");

        vm.expectRevert(MerkleTreeLib.LeafNotFoundInTree.selector);
        wrapper.getProofsUsingTree(fake, tree);
    }

    // --- Multiple proofs at once ---

    /// @notice Test getting multiple proofs at once
    function test_MultipleProofs() public pure {
        bytes32[] memory L = _leaves(6);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        // Get proofs for all leaves at once
        bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(L, tree);

        assertEq(proofs.length, 6, "Should have 6 proofs");

        for (uint256 i; i < L.length; ++i) {
            bytes32 computed = _processProof(L[i], proofs[i]);
            assertEq(computed, root, "Each proof should verify to root");
        }
    }

    // --- Fuzz tests ---

    /// @notice Fuzz test for various leaf counts
    function testFuzz_VariousLeafCounts(uint8 leafCount) public pure {
        vm.assume(leafCount > 0 && leafCount <= 32); // Reasonable bounds

        bytes32[] memory L = _leaves(leafCount);
        bytes32[][] memory tree = MerkleTreeLib.generateMerkleTree(L);
        bytes32 root = tree[tree.length - 1][0];

        // Verify first and last leaf proofs
        bytes32[] memory single = new bytes32[](1);

        // First leaf
        single[0] = L[0];
        bytes32[][] memory proofs = MerkleTreeLib.getProofsUsingTree(single, tree);
        bytes32 computed = _processProof(L[0], proofs[0]);
        assertEq(computed, root, "First leaf proof should verify");

        // Last leaf
        single[0] = L[leafCount - 1];
        proofs = MerkleTreeLib.getProofsUsingTree(single, tree);
        computed = _processProof(L[leafCount - 1], proofs[0]);
        assertEq(computed, root, "Last leaf proof should verify");
    }
}

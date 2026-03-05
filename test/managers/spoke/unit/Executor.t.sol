// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IExecutor} from "../../../../src/managers/spoke/interfaces/IExecutor.sol";
import {IExecutorFactory} from "../../../../src/managers/spoke/interfaces/IExecutorFactory.sol";

import "forge-std/Test.sol";

// ─── Mock target for weiroll commands ─────────────────────────────────────────

contract WeirollTarget {
    uint256 public lastValue;

    function setValue(uint256 v) external {
        lastValue = v;
    }

    function getValue() external view returns (uint256) {
        return lastValue;
    }

    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    function setValuePayable(uint256 v) external payable {
        lastValue = v;
    }

    function alwaysReverts() external pure {
        revert("target reverted");
    }

    receive() external payable {}
}

// ─── Base test ────────────────────────────────────────────────────────────────

contract ExecutorTest is Test {
    using CastLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    // Weiroll call type flags (byte 4 of command)
    uint256 constant FLAG_CT_CALL = 0x01;
    uint256 constant FLAG_CT_STATICCALL = 0x02;
    uint256 constant FLAG_CT_VALUECALL = 0x03;

    address contractUpdater = makeAddr("contractUpdater");
    address strategist = makeAddr("strategist");
    address unauthorized = makeAddr("unauthorized");

    IExecutor executor;
    WeirollTarget target;

    function setUp() public virtual {
        executor = IExecutor(deployCode("out-ir/Executor.sol/Executor.json", abi.encode(POOL_A, contractUpdater)));
        target = new WeirollTarget();
    }

    // ─── Weiroll command builder helpers ──────────────────────────────────

    /// @dev Build a weiroll command bytes32.
    ///      Layout: [0..3] selector, [4] flags, [5..10] indices, [11] output, [12..31] target(20 bytes)
    function _buildCommand(bytes4 selector, uint8 flags, bytes6 indices, uint8 output, address target_)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            (uint256(uint32(selector)) << 224) | (uint256(flags) << 216) | (uint256(uint48(indices)) << 168)
                | (uint256(output) << 160) | uint256(uint160(target_))
        );
    }

    /// @dev Short-hand for a CALL command with one fixed uint256 input from state[inputIdx],
    ///      no output (0xff = discard).
    function _callCommand(bytes4 selector, uint8 inputIdx, address target_) internal pure returns (bytes32) {
        bytes6 indices = bytes6(uint48(uint256(inputIdx) << 40 | 0xFFFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_CALL), indices, 0xff, target_);
    }

    /// @dev STATICCALL with no inputs, output stored at state[outputIdx].
    function _staticCallNoInputs(bytes4 selector, uint8 outputIdx, address target_) internal pure returns (bytes32) {
        bytes6 indices = bytes6(uint48(0xFFFFFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_STATICCALL), indices, outputIdx, target_);
    }

    /// @dev CALL with two inputs from state[idx0] and state[idx1], no output.
    function _callCommand2(bytes4 selector, uint8 idx0, uint8 idx1, address target_) internal pure returns (bytes32) {
        bytes6 indices = bytes6(uint48(uint256(idx0) << 40 | uint256(idx1) << 32 | 0xFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_CALL), indices, 0xff, target_);
    }

    /// @dev STATICCALL with two inputs, output to state[outputIdx].
    function _staticCall2(bytes4 selector, uint8 idx0, uint8 idx1, uint8 outputIdx, address target_)
        internal
        pure
        returns (bytes32)
    {
        bytes6 indices = bytes6(uint48(uint256(idx0) << 40 | uint256(idx1) << 32 | 0xFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_STATICCALL), indices, outputIdx, target_);
    }

    /// @dev VALUECALL: first index is ETH value from state, second is the function arg.
    function _valueCallCommand(bytes4 selector, uint8 valueIdx, uint8 inputIdx, address target_)
        internal
        pure
        returns (bytes32)
    {
        bytes6 indices = bytes6(uint48(uint256(valueIdx) << 40 | uint256(inputIdx) << 32 | 0xFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_VALUECALL), indices, 0xff, target_);
    }

    // ─── Policy/hash helpers ─────────────────────────────────────────────

    function _setPolicy(address who, bytes32 root) internal {
        bytes memory payload = abi.encode(who.toBytes32(), root);
        vm.prank(contractUpdater);
        executor.trustedCall(POOL_A, SC_1, payload);
    }

    function _computeScriptHash(bytes32[] memory commands, bytes[] memory state, uint256 stateBitmap)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                keccak256(abi.encodePacked(commands)), _hashFixedState(state, stateBitmap), stateBitmap, state.length
            )
        );
    }

    function _hashFixedState(bytes[] memory state, uint256 stateBitmap) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i; i < state.length; i++) {
            if (stateBitmap & (1 << i) != 0) {
                packed = bytes.concat(packed, keccak256(state[i]));
            }
        }
        return keccak256(packed);
    }

    function _merkleRoot2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // ─── Constructor / receive tests ─────────────────────────────────────

    function testConstructor() public view {
        assertEq(executor.poolId().raw(), POOL_A.raw());
        assertEq(executor.contractUpdater(), contractUpdater);
    }

    function testReceiveEther() public {
        uint256 amount = 1 ether;
        (bool success,) = address(executor).call{value: amount}("");
        assertTrue(success);
        assertEq(address(executor).balance, amount);
    }
}

// ─── TrustedCall Failures ─────────────────────────────────────────────────────

contract ExecutorTrustedCallFailureTests is ExecutorTest {
    using CastLib for *;

    function testInvalidPoolId() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IExecutor.InvalidPoolId.selector);
        vm.prank(contractUpdater);
        executor.trustedCall(POOL_B, SC_1, payload);
    }

    function testNotAuthorized() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IExecutor.NotAuthorized.selector);
        vm.prank(unauthorized);
        executor.trustedCall(POOL_A, SC_1, payload);
    }
}

// ─── TrustedCall Successes ────────────────────────────────────────────────────

contract ExecutorTrustedCallSuccessTests is ExecutorTest {
    using CastLib for *;

    function testTrustedCallPolicySuccess() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectEmit();
        emit IExecutor.UpdatePolicy(strategist, bytes32(0), rootHash);

        vm.prank(contractUpdater);
        executor.trustedCall(POOL_A, SC_1, payload);

        assertEq(executor.policy(strategist), rootHash);
    }

    function testTrustedCallPolicyUpdate() public {
        bytes32 oldRoot = keccak256("oldRoot");
        bytes32 newRoot = keccak256("newRoot");

        _setPolicy(strategist, oldRoot);
        assertEq(executor.policy(strategist), oldRoot);

        vm.expectEmit();
        emit IExecutor.UpdatePolicy(strategist, oldRoot, newRoot);

        _setPolicy(strategist, newRoot);
        assertEq(executor.policy(strategist), newRoot);
    }

    function testTrustedCallMultipleStrategists() public {
        address strategist1 = makeAddr("strategist1");
        address strategist2 = makeAddr("strategist2");
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        _setPolicy(strategist1, root1);
        _setPolicy(strategist2, root2);

        assertEq(executor.policy(strategist1), root1);
        assertEq(executor.policy(strategist2), root2);
    }

    function testTrustedCallClearPolicy() public {
        bytes32 rootHash = keccak256("root");
        _setPolicy(strategist, rootHash);

        vm.expectEmit();
        emit IExecutor.UpdatePolicy(strategist, rootHash, bytes32(0));

        _setPolicy(strategist, bytes32(0));
        assertEq(executor.policy(strategist), bytes32(0));
    }
}

// ─── Execute ──────────────────────────────────────────────────────────────────

contract ExecutorExecuteTests is ExecutorTest {
    function testNotAStrategist() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        vm.expectRevert(IExecutor.NotAStrategist.selector);
        vm.prank(unauthorized);
        executor.execute(commands, state, 0, new bytes32[](0));
    }

    function testSingleCallAllFixed() public {
        // setValue(42) — state[0] = abi.encode(42), bitmap bit 0 set (fixed)
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));

        uint256 bitmap = 1; // bit 0 set

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.expectEmit();
        emit IExecutor.ExecuteScript(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 42);
    }

    function testStaticCallThenCall() public {
        // Action 0: staticcall getValue() → state[1]
        // Action 1: call setValue(state[1])
        target.setValue(100);

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _staticCallNoInputs(WeirollTarget.getValue.selector, 1, address(target));
        commands[1] = _callCommand(WeirollTarget.setValue.selector, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = ""; // unused
        state[1] = abi.encode(uint256(0)); // placeholder for getValue result

        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 100);
    }

    function testStaticCallChainComposition() public {
        // staticcall add(10, 20) → state[2], then call setValue(state[2])
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _staticCall2(WeirollTarget.add.selector, 0, 1, 2, address(target));
        commands[1] = _callCommand(WeirollTarget.setValue.selector, 2, address(target));

        bytes[] memory state = new bytes[](3);
        state[0] = abi.encode(uint256(10));
        state[1] = abi.encode(uint256(20));
        state[2] = abi.encode(uint256(0)); // placeholder for add result

        uint256 bitmap = 3; // bits 0,1

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 30);
    }

    function testVariableStateBitUnset() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap);
        _setPolicy(strategist, scriptHash);

        bytes[] memory execState = new bytes[](1);
        execState[0] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 999);
    }

    function testFixedStateTamperReverts() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint256 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap);
        _setPolicy(strategist, scriptHash);

        bytes[] memory tamperedState = new bytes[](1);
        tamperedState[0] = abi.encode(uint256(999));

        vm.expectRevert(IExecutor.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, tamperedState, bitmap, new bytes32[](0));
    }

    function testMerkleProofWithMultipleLeaves() public {
        // Script A: setValue(42)
        bytes32[] memory commandsA = new bytes32[](1);
        commandsA[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(uint256(42));
        uint256 bitmapA = 1;
        bytes32 leafA = _computeScriptHash(commandsA, stateA, bitmapA);

        // Script B: setValue(99)
        bytes32[] memory commandsB = new bytes32[](1);
        commandsB[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(uint256(99));
        uint256 bitmapB = 1;
        bytes32 leafB = _computeScriptHash(commandsB, stateB, bitmapB);

        bytes32 root = _merkleRoot2(leafA, leafB);

        _setPolicy(strategist, root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.prank(strategist);
        executor.execute(commandsA, stateA, bitmapA, proof);
        assertEq(target.lastValue(), 42);

        proof[0] = leafA;

        vm.prank(strategist);
        executor.execute(commandsB, stateB, bitmapB, proof);
        assertEq(target.lastValue(), 99);
    }

    function testStateLengthOverflow() public {
        _setPolicy(strategist, keccak256("root"));

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](257);

        vm.expectRevert(IExecutor.StateLengthOverflow.selector);
        vm.prank(strategist);
        executor.execute(commands, state, 0, new bytes32[](0));
    }

    function testWeirollRevertPropagation() public {
        bytes32[] memory commands = new bytes32[](1);
        bytes6 indices = bytes6(uint48(0xFFFFFFFFFFFF));
        commands[0] =
            _buildCommand(WeirollTarget.alwaysReverts.selector, uint8(FLAG_CT_CALL), indices, 0xff, address(target));

        bytes[] memory state = new bytes[](0);
        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.expectRevert(); // ExecutionFailed from VM
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));
    }

    function testInvalidProofReverts() public {
        bytes32 wrongRoot = keccak256("wrong");
        _setPolicy(strategist, wrongRoot);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));
        uint256 bitmap = 1;

        vm.expectRevert(IExecutor.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));
    }

    function testValueCall() public {
        // Send 1 ETH along with setValuePayable(42)
        vm.deal(address(executor), 2 ether);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _valueCallCommand(WeirollTarget.setValuePayable.selector, 0, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(uint256(1 ether)); // ETH value
        state[1] = abi.encode(uint256(42)); // function arg

        uint256 bitmap = 3; // both fixed

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 42);
        assertEq(address(target).balance, 1 ether);
    }

    function testMixedFixedAndVariableState() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand2(WeirollTarget.setValue.selector, 0, 1, address(target));

        bytes[] memory authState = new bytes[](2);
        authState[0] = abi.encode(uint256(42));
        authState[1] = abi.encode(uint256(0));

        uint256 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap);
        _setPolicy(strategist, scriptHash);

        bytes[] memory execState = new bytes[](2);
        execState[0] = abi.encode(uint256(42));
        execState[1] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, new bytes32[](0));
    }
}

// ─── Callback bridge (mock for flash loan-like callback) ─────────────────────

contract CallbackBridge {
    function triggerCallback(
        IExecutor executor,
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint256 stateBitmap,
        bytes32[] calldata proof
    ) external {
        executor.executeCallback(commands, state, stateBitmap, proof);
    }
}

// ─── Nested callback bridge (for testing nested callback rejection) ──────────

contract NestedCallbackBridge {
    IExecutor public executor;
    bytes32[] public innerCommands;
    bytes[] public innerState;
    uint256 public innerBitmap;
    bytes32[] public innerProof;

    function setup(
        IExecutor executor_,
        bytes32[] calldata commands_,
        bytes[] calldata state_,
        uint256 bitmap_,
        bytes32[] calldata proof_
    ) external {
        executor = executor_;
        delete innerCommands;
        delete innerState;
        delete innerProof;
        for (uint256 i; i < commands_.length; i++) {
            innerCommands.push(commands_[i]);
        }
        for (uint256 i; i < state_.length; i++) {
            innerState.push(state_[i]);
        }
        innerBitmap = bitmap_;
        for (uint256 i; i < proof_.length; i++) {
            innerProof.push(proof_[i]);
        }
    }

    function triggerCallback(
        IExecutor executor_,
        bytes32[] calldata commands_,
        bytes[] calldata state_,
        uint256 stateBitmap_,
        bytes32[] calldata proof_
    ) external {
        executor_.executeCallback(commands_, state_, stateBitmap_, proof_);
    }

    /// @dev Called by the inner weiroll script to trigger a second (nested) callback.
    function reenter() external {
        executor.executeCallback(innerCommands, innerState, innerBitmap, innerProof);
    }
}

// ─── Callback Tests ──────────────────────────────────────────────────────────

contract ExecutorCallbackTests is ExecutorTest {
    CallbackBridge bridge;

    function setUp() public override {
        super.setUp();
        bridge = new CallbackBridge();
    }

    function testCallbackRevertsWhenNotInExecution() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        vm.expectRevert(IExecutor.NotInExecution.selector);
        bridge.triggerCallback(executor, commands, state, 0, new bytes32[](0));
    }

    function testCallbackRevertsInvalidProof() public {
        // Build an outer script that calls bridge.triggerCallback with a bad inner proof
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint256 innerBitmap = 1;

        // Encode callback data with an empty (invalid) proof
        bytes memory callbackData = abi.encode(innerCommands, innerState, innerBitmap, new bytes32[](0));

        // Outer script: call bridge.triggerCallback(executor, innerCommands, innerState, innerBitmap, proof)
        bytes32[] memory outerCommands = new bytes32[](1);
        // Use DATA flag (0x20) to pass raw calldata from state[0]
        outerCommands[0] = _buildCommand(
            CallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20, // CALL + DATA flag
            bytes6(uint48(0x00FFFFFFFFFF)), // state[0] as raw calldata
            0xff,
            address(bridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = abi.encodeWithSelector(
            CallbackBridge.triggerCallback.selector,
            address(executor),
            innerCommands,
            innerState,
            innerBitmap,
            new bytes32[](0) // invalid proof
        );
        uint256 outerBitmap = 1;
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap);

        // Policy is just the outer script hash (inner script is not in the tree → InvalidProof)
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // InvalidProof from the inner executeCallback
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, new bytes32[](0));
    }

    function testCallbackSuccess() public {
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint256 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCommands, innerState, innerBitmap);

        // Outer script: call bridge.triggerCallback(executor, innerCommands, innerState, innerBitmap, proof)
        bytes32[] memory outerCommands = new bytes32[](1);
        outerCommands[0] = _buildCommand(
            CallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20, // CALL + DATA flag
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(bridge)
        );

        // Compute inner proof (sibling = outer hash)
        bytes32 outerHashForTree;
        // We need the outer hash to build the Merkle tree, but the outer hash depends on the proof
        // which depends on the tree. Solution: compute outer hash first with innerHash as sibling proof.
        bytes32[] memory innerProof = new bytes32[](1);

        // Build outer state with the inner proof placeholder — we'll compute the tree after
        bytes[] memory outerState = new bytes[](1);

        // First compute outer hash with a placeholder to find the Merkle root
        // The outer state contains the encoded triggerCallback call with the inner proof
        // Inner proof sibling will be the outer hash. But outer hash depends on outer state which contains
        // the inner proof... circular dependency.
        //
        // Solution: the inner proof sibling is the outerHash. Build tree as:
        //   root = hash(innerHash, outerHash)
        // innerProof = [outerHash], outerProof = [innerHash]

        // First, build outerState with innerProof = [placeholder]
        // Then compute outerHash, set innerProof[0] = outerHash, rebuild outerState, recompute outerHash.
        // Since outerState is fixed (bitmap bit set), changing it changes outerHash → still circular.
        //
        // Better approach: make outerState variable (bitmap bit 0 unset), so outerHash doesn't depend on state content.

        outerState[0] = abi.encodeWithSelector(
            CallbackBridge.triggerCallback.selector,
            address(executor),
            innerCommands,
            innerState,
            innerBitmap,
            new bytes32[](1) // placeholder
        );
        uint256 outerBitmap = 0; // state is variable → not hashed

        // Compute outer hash (commands are fixed, state is variable)
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap);

        // Build 2-leaf Merkle tree
        bytes32 root;
        if (uint256(innerHash) < uint256(outerHash)) {
            root = keccak256(abi.encodePacked(innerHash, outerHash));
        } else {
            root = keccak256(abi.encodePacked(outerHash, innerHash));
        }

        _setPolicy(strategist, root);

        // Now set the correct inner proof and rebuild outer state
        innerProof[0] = outerHash;
        outerState[0] = abi.encodeWithSelector(
            CallbackBridge.triggerCallback.selector,
            address(executor),
            innerCommands,
            innerState,
            innerBitmap,
            innerProof
        );

        // Outer proof
        bytes32[] memory outerProof = new bytes32[](1);
        outerProof[0] = innerHash;

        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, outerProof);

        assertEq(target.lastValue(), 77);
    }

    function testCallbackEmitsEvent() public {
        // Same setup as testCallbackSuccess
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint256 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCommands, innerState, innerBitmap);

        bytes32[] memory outerCommands = new bytes32[](1);
        outerCommands[0] = _buildCommand(
            CallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20,
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(bridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = ""; // placeholder
        uint256 outerBitmap = 0;
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap);

        bytes32 root;
        if (uint256(innerHash) < uint256(outerHash)) {
            root = keccak256(abi.encodePacked(innerHash, outerHash));
        } else {
            root = keccak256(abi.encodePacked(outerHash, innerHash));
        }
        _setPolicy(strategist, root);

        bytes32[] memory innerProof = new bytes32[](1);
        innerProof[0] = outerHash;
        outerState[0] = abi.encodeWithSelector(
            CallbackBridge.triggerCallback.selector,
            address(executor),
            innerCommands,
            innerState,
            innerBitmap,
            innerProof
        );

        bytes32[] memory outerProof = new bytes32[](1);
        outerProof[0] = innerHash;

        // Expect the inner script's ExecuteScript event
        vm.expectEmit();
        emit IExecutor.ExecuteScript(strategist, innerHash);

        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, outerProof);
    }

    function testCallbackStateLengthOverflow() public {
        // Build an outer script that calls bridge with inner state of length 257
        bytes[] memory bigState = new bytes[](257);
        bytes32[] memory innerCommands = new bytes32[](0);
        uint256 innerBitmap = 0;

        bytes32[] memory outerCommands = new bytes32[](1);
        outerCommands[0] = _buildCommand(
            CallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20,
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(bridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = abi.encodeWithSelector(
            CallbackBridge.triggerCallback.selector,
            address(executor),
            innerCommands,
            bigState,
            innerBitmap,
            new bytes32[](0)
        );
        uint256 outerBitmap = 0;
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap);
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // StateLengthOverflow from executeCallback
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, new bytes32[](0));
    }

    function testActiveStrategistClearedAfterExecution() public {
        // Run a simple execute
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));
        uint256 bitmap = 1;
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));

        // After execute() completes, callback should revert
        vm.expectRevert(IExecutor.NotInExecution.selector);
        bridge.triggerCallback(executor, commands, state, bitmap, new bytes32[](0));
    }

    function testCallbackRevertsOnNestedCallback() public {
        NestedCallbackBridge nestedBridge = new NestedCallbackBridge();

        // Inner script 2 (the nested one): setValue(99) — doesn't matter what it does
        bytes32[] memory inner2Commands = new bytes32[](1);
        inner2Commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory inner2State = new bytes[](1);
        inner2State[0] = abi.encode(uint256(99));
        uint256 inner2Bitmap = 1;

        // Inner script 1: calls nestedBridge.reenter() which triggers a second executeCallback
        bytes32[] memory inner1Commands = new bytes32[](1);
        bytes6 noInputs = bytes6(uint48(0xFFFFFFFFFFFF));
        inner1Commands[0] =
            _buildCommand(NestedCallbackBridge.reenter.selector, uint8(FLAG_CT_CALL), noInputs, 0xff, address(nestedBridge));
        bytes[] memory inner1State = new bytes[](0);
        uint256 inner1Bitmap = 0;
        bytes32 inner1Hash = _computeScriptHash(inner1Commands, inner1State, inner1Bitmap);

        // Outer script: calls nestedBridge.triggerCallback → executor.executeCallback (inner1)
        //   Inner1 calls nestedBridge.reenter() → executor.executeCallback (inner2) → should revert NestedCallback
        bytes32[] memory outerCommands = new bytes32[](1);
        outerCommands[0] = _buildCommand(
            NestedCallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20,
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(nestedBridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = ""; // placeholder
        uint256 outerBitmap = 0;
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap);

        // 2-leaf tree: inner1Hash + outerHash
        bytes32 root;
        if (uint256(inner1Hash) < uint256(outerHash)) {
            root = keccak256(abi.encodePacked(inner1Hash, outerHash));
        } else {
            root = keccak256(abi.encodePacked(outerHash, inner1Hash));
        }
        _setPolicy(strategist, root);

        // Setup the nested bridge with inner2 data (will be used in reenter)
        nestedBridge.setup(executor, inner2Commands, inner2State, inner2Bitmap, new bytes32[](0));

        // Build correct inner1 proof
        bytes32[] memory inner1Proof = new bytes32[](1);
        inner1Proof[0] = outerHash;

        outerState[0] = abi.encodeWithSelector(
            NestedCallbackBridge.triggerCallback.selector,
            address(executor),
            inner1Commands,
            inner1State,
            inner1Bitmap,
            inner1Proof
        );

        bytes32[] memory outerProof = new bytes32[](1);
        outerProof[0] = inner1Hash;

        vm.expectRevert(); // NestedCallback from the second executeCallback attempt
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, outerProof);
    }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

contract ExecutorFactoryTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address contractUpdater = makeAddr("contractUpdater");
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    IExecutorFactory factory;

    function setUp() public virtual {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        factory = IExecutorFactory(
            deployCode("out-ir/Executor.sol/ExecutorFactory.json", abi.encode(contractUpdater, address(balanceSheet)))
        );
    }

    function testConstructor() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.balanceSheet()), address(balanceSheet));
    }
}

contract ExecutorFactoryDeployTest is ExecutorFactoryTest {
    function testNewExecutorSuccess() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IExecutor exec = factory.newExecutor(POOL_A);

        assertEq(exec.poolId().raw(), POOL_A.raw());
        assertEq(exec.contractUpdater(), contractUpdater);
    }

    function testNewExecutorInvalidPoolId() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_B), abi.encode(false));

        vm.expectRevert(IExecutorFactory.InvalidPoolId.selector);
        factory.newExecutor(POOL_B);
    }

    function testNewExecutorDeterministic() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        factory.newExecutor(POOL_A);

        // Second call should revert because CREATE2 with same salt fails
        vm.expectRevert();
        factory.newExecutor(POOL_A);
    }

    function testNewExecutorEventEmission() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        vm.recordLogs();
        IExecutor exec = factory.newExecutor(POOL_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("DeployExecutor(uint64,address)"));
        assertEq(uint256(logs[0].topics[1]), POOL_A.raw());
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(exec));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IWeirollExecutor} from "../../../../src/managers/spoke/interfaces/IWeirollExecutor.sol";
import {IWeirollExecutorFactory} from "../../../../src/managers/spoke/interfaces/IWeirollExecutorFactory.sol";
import {WeirollExecutor, WeirollExecutorFactory} from "../../../../src/managers/spoke/WeirollExecutor.sol";

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

contract WeirollExecutorTest is Test {
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

    WeirollExecutor executor;
    WeirollTarget target;

    function setUp() public virtual {
        executor = new WeirollExecutor(POOL_A, contractUpdater);
        target = new WeirollTarget();
    }

    // ─── Weiroll command builder helpers ──────────────────────────────────

    /// @dev Build a weiroll command bytes32.
    ///      Layout: [0..3] selector, [4] flags, [5..10] indices, [11] output, [12..31] target(20 bytes)
    function _buildCommand(
        bytes4 selector,
        uint8 flags,
        bytes6 indices,
        uint8 output,
        address target_
    ) internal pure returns (bytes32) {
        return bytes32(
            (uint256(uint32(selector)) << 224) | (uint256(flags) << 216) | (uint256(uint48(indices)) << 168)
                | (uint256(output) << 160) | uint256(uint160(target_))
        );
    }

    /// @dev Short-hand for a CALL command with one fixed uint256 input from state[inputIdx],
    ///      no output (0xff = discard).
    function _callCommand(bytes4 selector, uint8 inputIdx, address target_) internal pure returns (bytes32) {
        // indices: [inputIdx, 0xff, 0xff, 0xff, 0xff, 0xff] — first index is the input, rest are end-of-args
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
                keccak256(abi.encodePacked(commands)), _hashFixedState(state, stateBitmap), stateBitmap
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

contract WeirollExecutorTrustedCallFailureTests is WeirollExecutorTest {
    using CastLib for *;

    function testInvalidPoolId() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IWeirollExecutor.InvalidPoolId.selector);
        vm.prank(contractUpdater);
        executor.trustedCall(POOL_B, SC_1, payload);
    }

    function testNotAuthorized() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IWeirollExecutor.NotAuthorized.selector);
        vm.prank(unauthorized);
        executor.trustedCall(POOL_A, SC_1, payload);
    }
}

// ─── TrustedCall Successes ────────────────────────────────────────────────────

contract WeirollExecutorTrustedCallSuccessTests is WeirollExecutorTest {
    using CastLib for *;

    function testTrustedCallPolicySuccess() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectEmit();
        emit IWeirollExecutor.UpdatePolicy(strategist, bytes32(0), rootHash);

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
        emit IWeirollExecutor.UpdatePolicy(strategist, oldRoot, newRoot);

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
        emit IWeirollExecutor.UpdatePolicy(strategist, rootHash, bytes32(0));

        _setPolicy(strategist, bytes32(0));
        assertEq(executor.policy(strategist), bytes32(0));
    }
}

// ─── Execute ──────────────────────────────────────────────────────────────────

contract WeirollExecutorExecuteTests is WeirollExecutorTest {
    function testNotAStrategist() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        vm.expectRevert(IWeirollExecutor.NotAStrategist.selector);
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
        emit IWeirollExecutor.ExecuteScript(strategist, scriptHash);

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

        // Only commands are fixed (bitmap = 0, no fixed state)
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

        // Fix the input values (bits 0,1), leave output slot variable (bit 2 unset)
        uint256 bitmap = 3; // bits 0,1

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 30);
    }

    function testVariableStateBitUnset() public {
        // state[0] is variable (bit 0 unset) — strategist can change value at runtime
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        // Authorize with value 42
        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint256 bitmap = 0; // no fixed bits — all variable

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap);
        _setPolicy(strategist, scriptHash);

        // Execute with different value 999 — should succeed since bit 0 is variable
        bytes[] memory execState = new bytes[](1);
        execState[0] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, new bytes32[](0));

        assertEq(target.lastValue(), 999);
    }

    function testFixedStateTamperReverts() public {
        // state[0] is fixed (bit 0 set) — strategist cannot change value
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint256 bitmap = 1; // bit 0 set = fixed

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap);
        _setPolicy(strategist, scriptHash);

        // Try to tamper: change the fixed value
        bytes[] memory tamperedState = new bytes[](1);
        tamperedState[0] = abi.encode(uint256(999));

        vm.expectRevert(IWeirollExecutor.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, tamperedState, bitmap, new bytes32[](0));
    }

    function testMerkleProofWithMultipleLeaves() public {
        // Two authorized scripts in a Merkle tree

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

        // Compute root: sorted pair hash (matches MerkleProofLib)
        bytes32 root;
        if (uint256(leafA) < uint256(leafB)) {
            root = keccak256(abi.encodePacked(leafA, leafB));
        } else {
            root = keccak256(abi.encodePacked(leafB, leafA));
        }

        _setPolicy(strategist, root);

        // Execute script A with leafB as proof
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.prank(strategist);
        executor.execute(commandsA, stateA, bitmapA, proof);
        assertEq(target.lastValue(), 42);

        // Execute script B with leafA as proof
        proof[0] = leafA;

        vm.prank(strategist);
        executor.execute(commandsB, stateB, bitmapB, proof);
        assertEq(target.lastValue(), 99);
    }

    function testStateLengthOverflow() public {
        _setPolicy(strategist, keccak256("root"));

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](257);

        vm.expectRevert(IWeirollExecutor.StateLengthOverflow.selector);
        vm.prank(strategist);
        executor.execute(commands, state, 0, new bytes32[](0));
    }

    function testWeirollRevertPropagation() public {
        // Command calls alwaysReverts() — should revert with ExecutionFailed
        bytes32[] memory commands = new bytes32[](1);
        bytes6 indices = bytes6(uint48(0xFFFFFFFFFFFF));
        commands[0] = _buildCommand(WeirollTarget.alwaysReverts.selector, uint8(FLAG_CT_CALL), indices, 0xff, address(target));

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

        vm.expectRevert(IWeirollExecutor.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, new bytes32[](0));
    }

    function testMixedFixedAndVariableState() public {
        // state[0] = fixed target address, state[1] = variable amount
        // Command: setValue(state[0]) — only one input for simplicity
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand2(WeirollTarget.setValue.selector, 0, 1, address(target));

        // Authorize: state[0] fixed, state[1] variable
        bytes[] memory authState = new bytes[](2);
        authState[0] = abi.encode(uint256(42)); // fixed
        authState[1] = abi.encode(uint256(0)); // variable placeholder

        uint256 bitmap = 1; // only bit 0 set

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap);
        _setPolicy(strategist, scriptHash);

        // Execute: state[0] must match, state[1] can be anything
        bytes[] memory execState = new bytes[](2);
        execState[0] = abi.encode(uint256(42)); // must match
        execState[1] = abi.encode(uint256(999)); // any value

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, new bytes32[](0));
    }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

contract WeirollExecutorFactoryTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address contractUpdater = makeAddr("contractUpdater");
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    WeirollExecutorFactory factory;

    function setUp() public virtual {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        factory = new WeirollExecutorFactory(contractUpdater, balanceSheet);
    }

    function testConstructor() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.balanceSheet()), address(balanceSheet));
    }
}

contract WeirollExecutorFactoryDeployTest is WeirollExecutorFactoryTest {
    function testNewWeirollExecutorSuccess() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IWeirollExecutor exec = factory.newWeirollExecutor(POOL_A);
        WeirollExecutor concreteExec = WeirollExecutor(payable(address(exec)));

        assertEq(concreteExec.poolId().raw(), POOL_A.raw());
        assertEq(concreteExec.contractUpdater(), contractUpdater);
    }

    function testNewWeirollExecutorInvalidPoolId() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_B), abi.encode(false));

        vm.expectRevert(IWeirollExecutorFactory.InvalidPoolId.selector);
        factory.newWeirollExecutor(POOL_B);
    }

    function testNewWeirollExecutorDeterministic() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        factory.newWeirollExecutor(POOL_A);

        // Second call should revert because CREATE2 with same salt fails
        vm.expectRevert();
        factory.newWeirollExecutor(POOL_A);
    }

    function testNewWeirollExecutorEventEmission() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        vm.recordLogs();
        IWeirollExecutor exec = factory.newWeirollExecutor(POOL_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("DeployWeirollExecutor(uint64,address)"));
        assertEq(uint256(logs[0].topics[1]), POOL_A.raw());
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(exec));
    }
}

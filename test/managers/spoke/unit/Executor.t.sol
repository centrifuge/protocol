// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";

import {IExecutor} from "../../../../src/managers/spoke/interfaces/IExecutor.sol";
import {IExecutorFactory} from "../../../../src/managers/spoke/interfaces/IExecutorFactory.sol";
import {ITrustedContractUpdate} from "../../../../src/core/utils/interfaces/IContractUpdate.sol";

import {WeirollTarget, ExecutorTestBase} from "../ExecutorTestBase.sol";

import "forge-std/Test.sol";

// ─── Base test ────────────────────────────────────────────────────────────────

contract ExecutorTest is ExecutorTestBase {
    using CastLib for *;

    address contractUpdater = makeAddr("contractUpdater");
    address strategist = makeAddr("strategist");
    address unauthorized = makeAddr("unauthorized");
    IGateway gateway = IGateway(makeAddr("gateway"));

    IExecutor executor;
    WeirollTarget target;

    function setUp() public virtual {
        executor = IExecutor(
            deployCode("out-ir/Executor.sol/Executor.json", abi.encode(POOL_A, contractUpdater, address(gateway)))
        );
        target = new WeirollTarget();
    }

    // ─── Convenience wrappers ─────────────────────────────────────────────

    function _setPolicy(address who, bytes32 root) internal {
        _setPolicy(executor, who, root, contractUpdater);
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
        executor.execute(commands, state, 0, bytes32(0), new bytes32[](0));
    }

    function testSingleCallAllFixed() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));

        uint256 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.expectEmit();
        emit IExecutor.ExecuteScript(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));

        assertEq(target.lastValue(), 42);
    }

    function testStaticCallThenCall() public {
        target.setValue(100);

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _staticCallNoInputs(WeirollTarget.getValue.selector, 1, address(target));
        commands[1] = _callCommand(WeirollTarget.setValue.selector, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = "";
        state[1] = abi.encode(uint256(0));

        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));

        assertEq(target.lastValue(), 100);
    }

    function testStaticCallChainComposition() public {
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _staticCall2(WeirollTarget.add.selector, 0, 1, 2, address(target));
        commands[1] = _callCommand(WeirollTarget.setValue.selector, 2, address(target));

        bytes[] memory state = new bytes[](3);
        state[0] = abi.encode(uint256(10));
        state[1] = abi.encode(uint256(20));
        state[2] = abi.encode(uint256(0));

        uint256 bitmap = 3;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));

        assertEq(target.lastValue(), 30);
    }

    function testVariableStateBitUnset() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        bytes[] memory execState = new bytes[](1);
        execState[0] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, bytes32(0), new bytes32[](0));

        assertEq(target.lastValue(), 999);
    }

    function testFixedStateTamperReverts() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint256 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        bytes[] memory tamperedState = new bytes[](1);
        tamperedState[0] = abi.encode(uint256(999));

        vm.expectRevert(IExecutor.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, tamperedState, bitmap, bytes32(0), new bytes32[](0));
    }

    function testMerkleProofWithMultipleLeaves() public {
        bytes32[] memory commandsA = new bytes32[](1);
        commandsA[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(uint256(42));
        uint256 bitmapA = 1;
        bytes32 leafA = _computeScriptHash(commandsA, stateA, bitmapA, bytes32(0));

        bytes32[] memory commandsB = new bytes32[](1);
        commandsB[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(uint256(99));
        uint256 bitmapB = 1;
        bytes32 leafB = _computeScriptHash(commandsB, stateB, bitmapB, bytes32(0));

        bytes32 root = _merkleRoot2(leafA, leafB);
        _setPolicy(strategist, root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.prank(strategist);
        executor.execute(commandsA, stateA, bitmapA, bytes32(0), proof);
        assertEq(target.lastValue(), 42);

        proof[0] = leafA;

        vm.prank(strategist);
        executor.execute(commandsB, stateB, bitmapB, bytes32(0), proof);
        assertEq(target.lastValue(), 99);
    }

    function testStateLengthOverflow() public {
        _setPolicy(strategist, keccak256("root"));

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](257);

        vm.expectRevert(IExecutor.StateLengthOverflow.selector);
        vm.prank(strategist);
        executor.execute(commands, state, 0, bytes32(0), new bytes32[](0));
    }

    function testWeirollRevertPropagation() public {
        bytes32[] memory commands = new bytes32[](1);
        bytes6 indices = bytes6(uint48(0xFFFFFFFFFFFF));
        commands[0] =
            _buildCommand(WeirollTarget.alwaysReverts.selector, uint8(FLAG_CT_CALL), indices, 0xff, address(target));

        bytes[] memory state = new bytes[](0);
        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.expectRevert(); // VM.ExecutionFailed (not importable)
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));
    }

    function testStateLengthExactly256() public {
        _setPolicy(strategist, keccak256("root"));

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](256);
        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));
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
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));
    }

    function testValueCall() public {
        vm.deal(address(executor), 2 ether);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _valueCallCommand(WeirollTarget.setValuePayable.selector, 0, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(uint256(1 ether));
        state[1] = abi.encode(uint256(42));

        uint256 bitmap = 3;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));

        assertEq(target.lastValue(), 42);
        assertEq(address(target).balance, 1 ether);
    }

    function testSelfCallTrustedCallReverts() public {
        // A weiroll command targeting the Executor's own trustedCall should revert
        // because msg.sender is the Executor itself, not the contractUpdater
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildCommand(
            ITrustedContractUpdate.trustedCall.selector,
            uint8(FLAG_CT_CALL) | 0x20, // FLAG_DATA
            bytes6(uint48(0x00FFFFFFFFFF)), // state[0] is raw calldata
            0xff,
            address(executor)
        );

        bytes memory payload = abi.encode(bytes32(uint256(uint160(strategist))), keccak256("malicious"));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encodeWithSelector(ITrustedContractUpdate.trustedCall.selector, POOL_A, SC_1, payload);
        uint256 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.expectRevert(); // NotAuthorized (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));
    }

    function testMixedFixedAndVariableState() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand2(WeirollTarget.setValue.selector, 0, 1, address(target));

        bytes[] memory authState = new bytes[](2);
        authState[0] = abi.encode(uint256(42));
        authState[1] = abi.encode(uint256(0));

        uint256 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        bytes[] memory execState = new bytes[](2);
        execState[0] = abi.encode(uint256(42));
        execState[1] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, bytes32(0), new bytes32[](0));
    }
}

// ─── Callback bridge (mock for flash loan-like callback) ─────────────────────

contract CallbackBridge {
    function triggerCallback(
        IExecutor executor,
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint256 stateBitmap
    ) external {
        executor.executeCallback(commands, state, stateBitmap);
    }
}

// ─── Nested callback bridge (for testing nested callback rejection) ──────────

contract NestedCallbackBridge {
    IExecutor public executor;
    bytes32[] public innerCommands;
    bytes[] public innerState;
    uint256 public innerBitmap;

    function setup(IExecutor executor_, bytes32[] calldata commands_, bytes[] calldata state_, uint256 bitmap_)
        external
    {
        executor = executor_;
        delete innerCommands;
        delete innerState;
        for (uint256 i; i < commands_.length; i++) {
            innerCommands.push(commands_[i]);
        }
        for (uint256 i; i < state_.length; i++) {
            innerState.push(state_[i]);
        }
        innerBitmap = bitmap_;
    }

    function triggerCallback(
        IExecutor executor_,
        bytes32[] calldata commands_,
        bytes[] calldata state_,
        uint256 bitmap_
    ) external {
        executor_.executeCallback(commands_, state_, bitmap_);
    }

    /// @dev Called by the inner weiroll script to trigger a second (nested) callback.
    function reenter() external {
        executor.executeCallback(innerCommands, innerState, innerBitmap);
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
        bridge.triggerCallback(executor, commands, state, 0);
    }

    function testCallbackRevertsInvalidCallback() public {
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint256 innerBitmap = 1;

        // Outer script calls bridge with inner script, but callbackHash is wrong (bytes32(0))
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
            CallbackBridge.triggerCallback.selector, address(executor), innerCommands, innerState, innerBitmap
        );
        uint256 outerBitmap = 0;

        // callbackHash = bytes32(0) → inner script hash won't match
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap, bytes32(0));
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // InvalidCallback (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, bytes32(0), new bytes32[](0));
    }

    function testCallbackSuccess() public {
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint256 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCommands, innerState, innerBitmap, bytes32(0));

        // Outer script calls bridge.triggerCallback with inner script
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
            CallbackBridge.triggerCallback.selector, address(executor), innerCommands, innerState, innerBitmap
        );
        uint256 outerBitmap = 0; // variable state (callbackData contains inner script)

        // Outer script hash binds to inner via callbackHash
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap, innerHash);
        _setPolicy(strategist, outerHash);

        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, innerHash, new bytes32[](0));

        assertEq(target.lastValue(), 77);
    }

    function testCallbackStateLengthOverflow() public {
        bytes[] memory bigState = new bytes[](257);
        bytes32[] memory innerCommands = new bytes32[](0);
        uint256 innerBitmap = 0;
        bytes32 innerHash = _computeScriptHash(innerCommands, bigState, innerBitmap, bytes32(0));

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
            CallbackBridge.triggerCallback.selector, address(executor), innerCommands, bigState, innerBitmap
        );
        uint256 outerBitmap = 0;
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap, innerHash);
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // StateLengthOverflow (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, innerHash, new bytes32[](0));
    }

    function testActiveStrategistClearedAfterExecution() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));
        uint256 bitmap = 1;
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, bytes32(0), new bytes32[](0));

        // After execute() completes, callback should revert
        vm.expectRevert(IExecutor.NotInExecution.selector);
        bridge.triggerCallback(executor, commands, state, bitmap);
    }

    function testCallbackRevertsOnNestedCallback() public {
        NestedCallbackBridge nestedBridge = new NestedCallbackBridge();

        // Inner script 2 (the nested one): setValue(99)
        bytes32[] memory inner2Commands = new bytes32[](1);
        inner2Commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory inner2State = new bytes[](1);
        inner2State[0] = abi.encode(uint256(99));
        uint256 inner2Bitmap = 1;

        // Inner script 1: calls nestedBridge.reenter() which triggers a second executeCallback
        bytes32[] memory inner1Commands = new bytes32[](1);
        bytes6 noInputs = bytes6(uint48(0xFFFFFFFFFFFF));
        inner1Commands[0] = _buildCommand(
            NestedCallbackBridge.reenter.selector, uint8(FLAG_CT_CALL), noInputs, 0xff, address(nestedBridge)
        );
        bytes[] memory inner1State = new bytes[](0);
        uint256 inner1Bitmap = 0;
        bytes32 inner1Hash = _computeScriptHash(inner1Commands, inner1State, inner1Bitmap, bytes32(0));

        // Setup the nested bridge with inner2 data (will be used in reenter)
        nestedBridge.setup(executor, inner2Commands, inner2State, inner2Bitmap);

        // Outer script: calls nestedBridge.triggerCallback → executor.executeCallback (inner1)
        //   Inner1 calls nestedBridge.reenter() → executor.executeCallback (inner2) → NestedCallback
        bytes32[] memory outerCommands = new bytes32[](1);
        outerCommands[0] = _buildCommand(
            NestedCallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20,
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(nestedBridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = abi.encodeWithSelector(
            NestedCallbackBridge.triggerCallback.selector, address(executor), inner1Commands, inner1State, inner1Bitmap
        );
        uint256 outerBitmap = 0;
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap, inner1Hash);
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // NestedCallback (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, inner1Hash, new bytes32[](0));
    }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

contract ExecutorFactoryTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address contractUpdater = makeAddr("contractUpdater");
    IGateway gateway = IGateway(makeAddr("gateway"));
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    IExecutorFactory factory;

    function setUp() public virtual {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        factory = IExecutorFactory(
            deployCode(
                "out-ir/Executor.sol/ExecutorFactory.json",
                abi.encode(contractUpdater, address(balanceSheet), address(gateway))
            )
        );
    }

    function testConstructor() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.balanceSheet()), address(balanceSheet));
        assertEq(address(factory.gateway()), address(gateway));
    }
}

contract ExecutorFactoryDeployTest is ExecutorFactoryTest {
    function testNewExecutorSuccess() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IExecutor exec = factory.newExecutor(POOL_A);

        assertEq(exec.poolId().raw(), POOL_A.raw());
        assertEq(exec.contractUpdater(), contractUpdater);
        assertEq(factory.executors(POOL_A), address(exec));
    }

    function testNewExecutorInvalidPoolId() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_B), abi.encode(false));

        vm.expectRevert(IExecutorFactory.InvalidPoolId.selector);
        factory.newExecutor(POOL_B);
    }

    function testNewExecutorAlreadyDeployed() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        factory.newExecutor(POOL_A);

        vm.expectRevert(IExecutorFactory.AlreadyDeployed.selector);
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

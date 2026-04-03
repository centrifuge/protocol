// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../../../../src/core/utils/interfaces/IContractUpdate.sol";

import {IOnchainPM} from "../../../../src/managers/spoke/interfaces/IOnchainPM.sol";
import {IOnchainPMFactory} from "../../../../src/managers/spoke/interfaces/IOnchainPMFactory.sol";

import "forge-std/Test.sol";

import {WeirollTarget, OnchainPMTestBase} from "../OnchainPMTestBase.sol";

// ─── Base test ────────────────────────────────────────────────────────────────

contract OnchainPMTest is OnchainPMTestBase {
    using CastLib for *;

    address contractUpdater = makeAddr("contractUpdater");
    address strategist = makeAddr("strategist");
    address unauthorized = makeAddr("unauthorized");
    IGateway gateway = IGateway(makeAddr("gateway"));

    IOnchainPM executor;
    WeirollTarget target;

    function setUp() public virtual {
        executor = IOnchainPM(
            deployCode("out-ir/OnchainPM.sol/OnchainPM.json", abi.encode(POOL_A, contractUpdater, address(gateway)))
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

contract OnchainPMTrustedCallFailureTests is OnchainPMTest {
    using CastLib for *;

    function testInvalidPoolId() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IOnchainPM.InvalidPoolId.selector);
        vm.prank(contractUpdater);
        executor.trustedCall(POOL_B, SC_1, payload);
    }

    function testNotAuthorized() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IOnchainPM.NotAuthorized.selector);
        vm.prank(unauthorized);
        executor.trustedCall(POOL_A, SC_1, payload);
    }
}

// ─── TrustedCall Successes ────────────────────────────────────────────────────

contract OnchainPMTrustedCallSuccessTests is OnchainPMTest {
    using CastLib for *;

    function testTrustedCallPolicySuccess() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectEmit();
        emit IOnchainPM.UpdatePolicy(strategist, bytes32(0), rootHash);

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
        emit IOnchainPM.UpdatePolicy(strategist, oldRoot, newRoot);

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
        emit IOnchainPM.UpdatePolicy(strategist, rootHash, bytes32(0));

        _setPolicy(strategist, bytes32(0));
        assertEq(executor.policy(strategist), bytes32(0));
    }
}

// ─── Execute ──────────────────────────────────────────────────────────────────

contract OnchainPMExecuteTests is OnchainPMTest {
    function testNotAStrategist() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        vm.expectRevert(IOnchainPM.NotAStrategist.selector);
        vm.prank(unauthorized);
        executor.execute(commands, state, 0, NO_CALLBACKS, new bytes32[](0));
    }

    function testSingleCallAllFixed() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));

        uint128 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.expectEmit();
        emit IOnchainPM.ExecuteScript(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

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

        uint128 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

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

        uint128 bitmap = 3;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

        assertEq(target.lastValue(), 30);
    }

    function testVariableStateBitUnset() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint128 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        bytes[] memory execState = new bytes[](1);
        execState[0] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, NO_CALLBACKS, new bytes32[](0));

        assertEq(target.lastValue(), 999);
    }

    function testFixedStateTamperReverts() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory authState = new bytes[](1);
        authState[0] = abi.encode(uint256(42));
        uint128 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        bytes[] memory tamperedState = new bytes[](1);
        tamperedState[0] = abi.encode(uint256(999));

        vm.expectRevert(IOnchainPM.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, tamperedState, bitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testMerkleProofWithMultipleLeaves() public {
        bytes32[] memory commandsA = new bytes32[](1);
        commandsA[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(uint256(42));
        uint128 bitmapA = 1;
        bytes32 leafA = _computeScriptHash(commandsA, stateA, bitmapA, NO_CALLBACKS);

        bytes32[] memory commandsB = new bytes32[](1);
        commandsB[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(uint256(99));
        uint128 bitmapB = 1;
        bytes32 leafB = _computeScriptHash(commandsB, stateB, bitmapB, NO_CALLBACKS);

        bytes32 root = _merkleRoot2(leafA, leafB);
        _setPolicy(strategist, root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.prank(strategist);
        executor.execute(commandsA, stateA, bitmapA, NO_CALLBACKS, proof);
        assertEq(target.lastValue(), 42);

        proof[0] = leafA;

        vm.prank(strategist);
        executor.execute(commandsB, stateB, bitmapB, NO_CALLBACKS, proof);
        assertEq(target.lastValue(), 99);
    }

    function testStateLengthOverflow() public {
        _setPolicy(strategist, keccak256("root"));

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](129);

        vm.expectRevert(IOnchainPM.StateLengthOverflow.selector);
        vm.prank(strategist);
        executor.execute(commands, state, 0, NO_CALLBACKS, new bytes32[](0));
    }

    function testWeirollRevertPropagation() public {
        bytes32[] memory commands = new bytes32[](1);
        bytes6 indices = bytes6(uint48(0xFFFFFFFFFFFF));
        commands[0] =
            _buildCommand(WeirollTarget.alwaysReverts.selector, uint8(FLAG_CT_CALL), indices, 0xff, address(target));

        bytes[] memory state = new bytes[](0);
        uint128 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.expectRevert(); // VM.ExecutionFailed (not importable)
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testStateLengthExactly128() public {
        _setPolicy(strategist, keccak256("root"));

        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](128);
        uint128 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testInvalidProofReverts() public {
        bytes32 wrongRoot = keccak256("wrong");
        _setPolicy(strategist, wrongRoot);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));
        uint128 bitmap = 1;

        vm.expectRevert(IOnchainPM.InvalidProof.selector);
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testValueCall() public {
        vm.deal(address(executor), 2 ether);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _valueCallCommand(WeirollTarget.setValuePayable.selector, 0, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(uint256(1 ether));
        state[1] = abi.encode(uint256(42));

        uint128 bitmap = 3;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

        assertEq(target.lastValue(), 42);
        assertEq(address(target).balance, 1 ether);
    }

    function testSelfCallTrustedCallReverts() public {
        // A weiroll command targeting the OnchainPM's own trustedCall should revert
        // because msg.sender is the OnchainPM itself, not the contractUpdater
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
        uint128 bitmap = 0;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.expectRevert(); // NotAuthorized (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testMixedFixedAndVariableState() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand2(WeirollTarget.setValue.selector, 0, 1, address(target));

        bytes[] memory authState = new bytes[](2);
        authState[0] = abi.encode(uint256(42));
        authState[1] = abi.encode(uint256(0));

        uint128 bitmap = 1;

        bytes32 scriptHash = _computeScriptHash(commands, authState, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        bytes[] memory execState = new bytes[](2);
        execState[0] = abi.encode(uint256(42));
        execState[1] = abi.encode(uint256(999));

        vm.prank(strategist);
        executor.execute(commands, execState, bitmap, NO_CALLBACKS, new bytes32[](0));
    }
}

// ─── Callback bridge (mock for flash loan-like callback) ─────────────────────

contract CallbackBridge {
    function triggerCallback(
        IOnchainPM executor,
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint128 stateBitmap
    ) external {
        executor.executeCallback(commands, state, stateBitmap);
    }
}

// ─── Nested callback bridge (for testing nested callback rejection) ──────────

contract NestedCallbackBridge {
    IOnchainPM public executor;
    bytes32[] public innerCommands;
    bytes[] public innerState;
    uint128 public innerBitmap;

    function setup(IOnchainPM executor_, bytes32[] calldata commands_, bytes[] calldata state_, uint128 bitmap_)
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
        IOnchainPM executor_,
        bytes32[] calldata commands_,
        bytes[] calldata state_,
        uint128 bitmap_
    ) external {
        executor_.executeCallback(commands_, state_, bitmap_);
    }

    /// @dev Called by the inner weiroll script to trigger a second (nested) callback.
    function reenter() external {
        executor.executeCallback(innerCommands, innerState, innerBitmap);
    }
}

// ─── Callback Tests ──────────────────────────────────────────────────────────

contract OnchainPMCallbackTests is OnchainPMTest {
    CallbackBridge bridge;

    function setUp() public override {
        super.setUp();
        bridge = new CallbackBridge();
    }

    function testCallbackRevertsWhenNotInExecution() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        vm.expectRevert(IOnchainPM.NotInExecution.selector);
        bridge.triggerCallback(executor, commands, state, 0);
    }

    function testCallbackRevertsInvalidCallback() public {
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint128 innerBitmap = 1;

        // Outer script calls bridge with inner script, but no callbacks pre-committed
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
        uint128 outerBitmap = 0;

        // NO_CALLBACKS → inner script hash won't match
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap, NO_CALLBACKS);
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // CallbackExhausted (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testCallbackSuccess() public {
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint128 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCommands, innerState, innerBitmap, NO_CALLBACKS);

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
        uint128 outerBitmap = 0; // variable state (callbackData contains inner script)

        // Outer script hash binds to inner via callbackHashes + callbackCallers
        bytes32 outerHash =
            _computeScriptHash(outerCommands, outerState, outerBitmap, _callback(innerHash, address(bridge)));
        _setPolicy(strategist, outerHash);

        vm.prank(strategist);
        executor.execute(
            outerCommands, outerState, outerBitmap, _callback(innerHash, address(bridge)), new bytes32[](0)
        );

        assertEq(target.lastValue(), 77);
    }

    function testCallbackRevertsWrongCaller() public {
        // Inner script: setValue(77)
        bytes32[] memory innerCommands = new bytes32[](1);
        innerCommands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint128 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCommands, innerState, innerBitmap, NO_CALLBACKS);

        // Register a DIFFERENT expected caller (not bridge)
        address wrongCaller = makeAddr("wrongCaller");

        // Outer script calls bridge.triggerCallback, but expected caller is wrongCaller
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
        uint128 outerBitmap = 0;

        bytes32 outerHash =
            _computeScriptHash(outerCommands, outerState, outerBitmap, _callback(innerHash, wrongCaller));
        _setPolicy(strategist, outerHash);

        // bridge calls executeCallback but msg.sender (bridge) != expectedCaller (wrongCaller)
        vm.expectRevert(); // InvalidCallbackCaller (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, _callback(innerHash, wrongCaller), new bytes32[](0));
    }

    function testCallbackNoCallbacksSucceeds() public {
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);
        uint128 bitmap = 0;

        // No callbacks — empty Callback[] passes trivially
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
    }

    function testCallbackStateLengthOverflow() public {
        bytes[] memory bigState = new bytes[](257);
        bytes32[] memory innerCommands = new bytes32[](0);
        uint128 innerBitmap = 0;
        bytes32 innerHash = _computeScriptHash(innerCommands, bigState, innerBitmap, NO_CALLBACKS);

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
        uint128 outerBitmap = 0;
        bytes32 outerHash =
            _computeScriptHash(outerCommands, outerState, outerBitmap, _callback(innerHash, address(bridge)));
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // StateLengthOverflow (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(
            outerCommands, outerState, outerBitmap, _callback(innerHash, address(bridge)), new bytes32[](0)
        );
    }

    function testActiveStrategistClearedAfterExecution() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));
        uint128 bitmap = 1;
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

        // After execute() completes, callback should revert
        vm.expectRevert(IOnchainPM.NotInExecution.selector);
        bridge.triggerCallback(executor, commands, state, bitmap);
    }

    function testCallbackRevertsOnCallbackExhausted() public {
        NestedCallbackBridge nestedBridge = new NestedCallbackBridge();

        // Inner script 2 (the nested one): setValue(99)
        bytes32[] memory inner2Commands = new bytes32[](1);
        inner2Commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory inner2State = new bytes[](1);
        inner2State[0] = abi.encode(uint256(99));
        uint128 inner2Bitmap = 1;

        // Inner script 1: calls nestedBridge.reenter() which triggers a second executeCallback
        // Only 1 callback hash is pre-committed, but 2 callbacks are attempted → CallbackExhausted
        bytes32[] memory inner1Commands = new bytes32[](1);
        bytes6 noInputs = bytes6(uint48(0xFFFFFFFFFFFF));
        inner1Commands[0] = _buildCommand(
            NestedCallbackBridge.reenter.selector, uint8(FLAG_CT_CALL), noInputs, 0xff, address(nestedBridge)
        );
        bytes[] memory inner1State = new bytes[](0);
        uint128 inner1Bitmap = 0;
        bytes32 inner1Hash = _computeScriptHash(inner1Commands, inner1State, inner1Bitmap, NO_CALLBACKS);

        // Setup the nested bridge with inner2 data (will be used in reenter)
        nestedBridge.setup(executor, inner2Commands, inner2State, inner2Bitmap);

        // Outer script: calls nestedBridge.triggerCallback → executor.executeCallback (inner1)
        //   Inner1 calls nestedBridge.reenter() → executor.executeCallback (inner2) → CallbackExhausted
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
        uint128 outerBitmap = 0;
        IOnchainPM.Callback[] memory callbacks = _callback(inner1Hash, address(nestedBridge));
        bytes32 outerHash = _computeScriptHash(outerCommands, outerState, outerBitmap, callbacks);
        _setPolicy(strategist, outerHash);

        vm.expectRevert(); // CallbackExhausted (wrapped by VM.ExecutionFailed)
        vm.prank(strategist);
        executor.execute(outerCommands, outerState, outerBitmap, callbacks, new bytes32[](0));
    }
}

// ─── Sequential callback bridge (triggers two callbacks in order) ────────────

contract SequentialCallbackBridge {
    function triggerTwoCallbacks(
        IOnchainPM executor_,
        bytes32[] calldata cmds1,
        bytes[] calldata state1,
        uint128 bitmap1,
        bytes32[] calldata cmds2,
        bytes[] calldata state2,
        uint128 bitmap2
    ) external {
        executor_.executeCallback(cmds1, state1, bitmap1);
        executor_.executeCallback(cmds2, state2, bitmap2);
    }
}

// ─── Additional Callback Tests ──────────────────────────────────────────────

contract OnchainPMSequentialCallbackTests is OnchainPMTest {
    SequentialCallbackBridge seqBridge;
    CallbackBridge bridge;

    function setUp() public override {
        super.setUp();
        seqBridge = new SequentialCallbackBridge();
        bridge = new CallbackBridge();
    }

    function testSequentialMultiCallbackConsumption() public {
        // Inner script 1: setValue(11)
        bytes32[] memory inner1Cmds = new bytes32[](1);
        inner1Cmds[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory inner1State = new bytes[](1);
        inner1State[0] = abi.encode(uint256(11));
        uint128 inner1Bitmap = 1;
        bytes32 inner1Hash = _computeScriptHash(inner1Cmds, inner1State, inner1Bitmap, NO_CALLBACKS);

        // Inner script 2: setValue(22)
        bytes32[] memory inner2Cmds = new bytes32[](1);
        inner2Cmds[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory inner2State = new bytes[](1);
        inner2State[0] = abi.encode(uint256(22));
        uint128 inner2Bitmap = 1;
        bytes32 inner2Hash = _computeScriptHash(inner2Cmds, inner2State, inner2Bitmap, NO_CALLBACKS);

        // Outer script: seqBridge.triggerTwoCallbacks(...)
        bytes32[] memory outerCmds = new bytes32[](1);
        outerCmds[0] = _buildCommand(
            SequentialCallbackBridge.triggerTwoCallbacks.selector,
            uint8(FLAG_CT_CALL) | 0x20, // FLAG_DATA
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(seqBridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = abi.encodeWithSelector(
            SequentialCallbackBridge.triggerTwoCallbacks.selector,
            address(executor),
            inner1Cmds,
            inner1State,
            inner1Bitmap,
            inner2Cmds,
            inner2State,
            inner2Bitmap
        );
        uint128 outerBitmap = 0;

        IOnchainPM.Callback[] memory callbacks =
            _callbacks(inner1Hash, address(seqBridge), inner2Hash, address(seqBridge));
        bytes32 outerHash = _computeScriptHash(outerCmds, outerState, outerBitmap, callbacks);
        _setPolicy(strategist, outerHash);

        vm.prank(strategist);
        executor.execute(outerCmds, outerState, outerBitmap, callbacks, new bytes32[](0));

        // Second callback ran last → setValue(22)
        assertEq(target.lastValue(), 22);
    }

    function testUnconsumedCallbacksReverts() public {
        // Pre-commit 2 callback hashes but only consume 1 → UnconsumedCallbacks
        bytes32[] memory innerCmds = new bytes32[](1);
        innerCmds[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(42));
        uint128 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCmds, innerState, innerBitmap, NO_CALLBACKS);

        bytes32 unusedHash = keccak256("unused");

        // Outer script: bridge.triggerCallback → consumes only innerHash
        bytes32[] memory outerCmds = new bytes32[](1);
        outerCmds[0] = _buildCommand(
            CallbackBridge.triggerCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20,
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(bridge)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = abi.encodeWithSelector(
            CallbackBridge.triggerCallback.selector, address(executor), innerCmds, innerState, innerBitmap
        );
        uint128 outerBitmap = 0;

        IOnchainPM.Callback[] memory callbacks = _callbacks(innerHash, address(bridge), unusedHash, address(bridge));
        bytes32 outerHash = _computeScriptHash(outerCmds, outerState, outerBitmap, callbacks);
        _setPolicy(strategist, outerHash);

        vm.expectRevert(IOnchainPM.UnconsumedCallbacks.selector);
        vm.prank(strategist);
        executor.execute(outerCmds, outerState, outerBitmap, callbacks, new bytes32[](0));
    }
}

// ─── Self-call executeCallback Tests ────────────────────────────────────────

contract OnchainPMSelfCallTests is OnchainPMTest {
    function testSelfCallExecuteCallbackReverts() public {
        // Inner script: setValue(77) — valid script
        bytes32[] memory innerCmds = new bytes32[](1);
        innerCmds[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory innerState = new bytes[](1);
        innerState[0] = abi.encode(uint256(77));
        uint128 innerBitmap = 1;
        bytes32 innerHash = _computeScriptHash(innerCmds, innerState, innerBitmap, NO_CALLBACKS);

        // Outer script: weiroll command targeting executor.executeCallback directly
        bytes32[] memory outerCmds = new bytes32[](1);
        outerCmds[0] = _buildCommand(
            IOnchainPM.executeCallback.selector,
            uint8(FLAG_CT_CALL) | 0x20, // FLAG_DATA
            bytes6(uint48(0x00FFFFFFFFFF)),
            0xff,
            address(executor)
        );

        bytes[] memory outerState = new bytes[](1);
        outerState[0] = abi.encodeWithSelector(IOnchainPM.executeCallback.selector, innerCmds, innerState, innerBitmap);
        uint128 outerBitmap = 0;

        bytes32 outerHash =
            _computeScriptHash(outerCmds, outerState, outerBitmap, _callback(innerHash, address(executor)));
        _setPolicy(strategist, outerHash);

        // Weiroll CALL from executor to itself → SelfCallForbidden (wrapped by VM.ExecutionFailed)
        vm.expectRevert();
        vm.prank(strategist);
        executor.execute(outerCmds, outerState, outerBitmap, _callback(innerHash, address(executor)), new bytes32[](0));
    }
}

// ─── Script Hash Fuzz Tests ─────────────────────────────────────────────────

contract OnchainPMScriptHashFuzzTests is OnchainPMTest {
    function testFuzzScriptHashDeterministic(uint128 bitmap, uint8 stateLen) public view {
        stateLen = uint8(bound(stateLen, 0, 16)); // keep reasonable
        bitmap = bitmap & uint128((uint256(1) << stateLen) - 1); // only valid bits

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](stateLen);
        for (uint256 i; i < stateLen; i++) {
            state[i] = abi.encode(i);
        }

        bytes32 hash1 = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        bytes32 hash2 = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        assertEq(hash1, hash2);
    }

    function testFuzzDifferentBitmapsDifferentHashes(uint128 bitmapA, uint128 bitmapB) public view {
        // 4 state elements, constrain bitmaps to 4 bits
        bitmapA = bitmapA & 0xF;
        bitmapB = bitmapB & 0xF;
        vm.assume(bitmapA != bitmapB);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory state = new bytes[](4);
        for (uint256 i; i < 4; i++) {
            state[i] = abi.encode(i + 1); // non-zero, distinct values
        }

        bytes32 hashA = _computeScriptHash(commands, state, bitmapA, NO_CALLBACKS);
        bytes32 hashB = _computeScriptHash(commands, state, bitmapB, NO_CALLBACKS);
        assertNotEq(hashA, hashB);
    }

    function testFuzzDifferentStateDifferentHashes(uint256 valA, uint256 valB) public view {
        vm.assume(valA != valB);

        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(valA);
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(valB);

        uint128 bitmap = 1; // state[0] is fixed
        assertNotEq(
            _computeScriptHash(commands, stateA, bitmap, NO_CALLBACKS),
            _computeScriptHash(commands, stateB, bitmap, NO_CALLBACKS)
        );
    }

    function testFuzzVariableStateIgnoredInHash(uint256 valA, uint256 valB) public view {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));

        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(valA);
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(valB);

        uint128 bitmap = 0; // state[0] is variable → not in hash
        assertEq(
            _computeScriptHash(commands, stateA, bitmap, NO_CALLBACKS),
            _computeScriptHash(commands, stateB, bitmap, NO_CALLBACKS)
        );
    }
}

// ─── Fixed Slots Tests ──────────────────────────────────────────────────────

contract OnchainPMFixedSlotsTests is OnchainPMTest {
    function testBitmapSlotUnmodifiedPasses() public {
        // Slot 0 in bitmap: protected. Script reads from slot 1 only → passes.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 1, address(target));
        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(uint256(0xdead)); // bitmap-protected, not written
        state[1] = abi.encode(uint256(42));
        uint128 bitmap = 3; // both slots in bitmap
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
        assertEq(target.lastValue(), 42);
    }

    function testZeroBitmapSkipsWriteProtection() public {
        // bitmap=0: no bits set, any write is allowed
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _staticCallNoInputs(WeirollTarget.getValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(0xdead));
        uint128 bitmap = 0;
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap);
        _setPolicy(strategist, scriptHash);

        vm.prank(strategist);
        executor.execute(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));
    }
}

// ─── ETH Forwarding Tests ───────────────────────────────────────────────────

contract OnchainPMEthForwardingTests is OnchainPMTest {
    function testExecuteWithMsgValue() public {
        // Send ETH with execute() and use it via valuecall
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _valueCallCommand(WeirollTarget.setValuePayable.selector, 0, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(uint256(1 ether));
        state[1] = abi.encode(uint256(42));
        uint128 bitmap = 3;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.deal(strategist, 1 ether);
        vm.prank(strategist);
        executor.execute{value: 1 ether}(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

        assertEq(target.lastValue(), 42);
        assertEq(address(target).balance, 1 ether);
        assertEq(address(executor).balance, 0);
    }

    function testExecuteWithExcessMsgValue() public {
        // Send more ETH than the script uses — remainder stays in executor
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _valueCallCommand(WeirollTarget.setValuePayable.selector, 0, 1, address(target));

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(uint256(0.5 ether));
        state[1] = abi.encode(uint256(7));
        uint128 bitmap = 3;

        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, NO_CALLBACKS);
        _setPolicy(strategist, scriptHash);

        vm.deal(strategist, 2 ether);
        vm.prank(strategist);
        executor.execute{value: 2 ether}(commands, state, bitmap, NO_CALLBACKS, new bytes32[](0));

        assertEq(address(target).balance, 0.5 ether);
        assertEq(address(executor).balance, 1.5 ether);
    }
}

// ─── Reentrancy ──────────────────────────────────────────────────────────────

/// @dev Contract strategist that reenters OnchainPM.execute() when called mid-script.
contract ReentrantStrategist {
    IOnchainPM public executor;
    bytes private reentryData;

    function configure(IOnchainPM executor_, bytes calldata reentryData_) external {
        executor = executor_;
        reentryData = reentryData_;
    }

    function trigger(bytes32[] calldata commands, bytes[] calldata state, uint128 bitmap, bytes32[] calldata proof)
        external
    {
        executor.execute(commands, state, bitmap, new IOnchainPM.Callback[](0), proof);
    }

    /// @dev Called by weiroll script — attempts to reenter execute() with a second leaf.
    function reenter() external {
        (bytes32[] memory commands, bytes[] memory state, uint128 bitmap, bytes32[] memory proof) =
            abi.decode(reentryData, (bytes32[], bytes[], uint128, bytes32[]));
        executor.execute(commands, state, bitmap, new IOnchainPM.Callback[](0), proof);
    }
}

contract OnchainPMReentrancyTests is OnchainPMTestBase {
    IGateway gateway = IGateway(makeAddr("gateway"));
    address contractUpdater = makeAddr("contractUpdater");

    IOnchainPM executor;
    WeirollTarget target;
    ReentrantStrategist strategist;

    function setUp() public {
        executor = IOnchainPM(
            deployCode("out-ir/OnchainPM.sol/OnchainPM.json", abi.encode(POOL_A, contractUpdater, address(gateway)))
        );
        target = new WeirollTarget();
        strategist = new ReentrantStrategist();
    }

    function testReentrantExecuteReverts() public {
        // Leaf B: target.setValue(42)
        bytes32[] memory commandsB = new bytes32[](1);
        commandsB[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(uint256(42));
        uint128 bitmapB = 1;
        bytes32 leafB = _computeScriptHash(commandsB, stateB, bitmapB, NO_CALLBACKS);

        // Leaf A: call strategist.reenter() (which attempts to execute leaf B)
        bytes32[] memory commandsA = new bytes32[](1);
        commandsA[0] = _buildCommand(
            ReentrantStrategist.reenter.selector,
            uint8(FLAG_CT_CALL),
            bytes6(uint48(0xFFFFFFFFFFFF)),
            0xff,
            address(strategist)
        );
        bytes[] memory stateA = new bytes[](0);
        uint128 bitmapA = 0;
        bytes32 leafA = _computeScriptHash(commandsA, stateA, bitmapA, NO_CALLBACKS);

        // Build merkle tree with both leaves
        bytes32 root = _merkleRoot2(leafA, leafB);
        _setPolicy(executor, address(strategist), root, contractUpdater);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;

        // Configure strategist to reenter with leaf B
        strategist.configure(executor, abi.encode(commandsB, stateB, bitmapB, proofB));

        // Reentrant execution must revert (AlreadyExecuting, wrapped by weiroll VM)
        vm.expectRevert();
        strategist.trigger(commandsA, stateA, bitmapA, proofA);

        // Verify target was not modified
        assertEq(target.lastValue(), 0);
    }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

contract OnchainPMFactoryTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address contractUpdater = makeAddr("contractUpdater");
    IGateway gateway = IGateway(makeAddr("gateway"));
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    IOnchainPMFactory factory;

    function setUp() public virtual {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        factory = IOnchainPMFactory(
            deployCode(
                "out-ir/OnchainPM.sol/OnchainPMFactory.json",
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

contract OnchainPMFactoryDeployTest is OnchainPMFactoryTest {
    function testNewOnchainPMSuccess() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IOnchainPM exec = factory.newOnchainPM(POOL_A);

        assertEq(exec.poolId().raw(), POOL_A.raw());
        assertEq(exec.contractUpdater(), contractUpdater);
    }

    function testNewOnchainPMInvalidPoolId() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_B), abi.encode(false));

        vm.expectRevert(IOnchainPMFactory.InvalidPoolId.selector);
        factory.newOnchainPM(POOL_B);
    }

    function testNewOnchainPMAlreadyDeployedReverts() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        factory.newOnchainPM(POOL_A);

        // CREATE2 with same salt reverts on redeployment
        vm.expectRevert();
        factory.newOnchainPM(POOL_A);
    }

    function testNewOnchainPMEventEmission() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        vm.recordLogs();
        IOnchainPM exec = factory.newOnchainPM(POOL_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("DeployOnchainPM(uint64,address)"));
        assertEq(uint256(logs[0].topics[1]), POOL_A.raw());
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(exec));
    }
}

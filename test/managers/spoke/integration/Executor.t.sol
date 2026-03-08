// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {IBatchedMulticall} from "../../../../src/core/utils/interfaces/IBatchedMulticall.sol";
import {IMulticall} from "../../../../src/misc/interfaces/IMulticall.sol";

import {IExecutor} from "../../../../src/managers/spoke/interfaces/IExecutor.sol";

import {WeirollTarget, ExecutorTestBase} from "../ExecutorTestBase.sol";

import "forge-std/Test.sol";

// ─── Mock gateway simulating withBatch/lockCallback ──────────────────────────

contract MockGateway {
    address internal transient _batcher;

    function withBatch(bytes memory data, address) external payable {
        _batcher = msg.sender;
        (bool success, bytes memory returnData) = msg.sender.call(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, "call-failed-empty-revert");

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }
    }

    function lockCallback() external returns (address caller) {
        caller = _batcher;
        _batcher = address(0);
    }
}

// ─── Base ────────────────────────────────────────────────────────────────────

contract ExecutorMulticallTest is ExecutorTestBase {
    using CastLib for *;

    address contractUpdater = makeAddr("contractUpdater");
    address strategist = makeAddr("strategist");
    MockGateway mockGateway;
    IExecutor executor;
    WeirollTarget target;

    function setUp() public virtual {
        mockGateway = new MockGateway();
        executor = IExecutor(
            deployCode("out-ir/Executor.sol/Executor.json", abi.encode(POOL_A, contractUpdater, address(mockGateway)))
        );
        target = new WeirollTarget();
    }

    // ─── Convenience wrappers ─────────────────────────────────────────────

    function _setPolicy(address who, bytes32 root) internal {
        _setPolicy(executor, who, root, contractUpdater);
    }

    /// @dev Build a script, set its policy, and return the calldata for executor.execute().
    function _prepareScript(bytes32[] memory commands, bytes[] memory state, uint256 bitmap)
        internal
        returns (bytes memory)
    {
        bytes32 scriptHash = _computeScriptHash(commands, state, bitmap, bytes32(0));
        _setPolicy(strategist, scriptHash);
        return abi.encodeWithSelector(IExecutor.execute.selector, commands, state, bitmap, bytes32(0), new bytes32[](0));
    }
}

// ─── Multicall executes batched scripts ──────────────────────────────────────

contract ExecutorMulticallBatchTest is ExecutorMulticallTest {
    function testMulticallExecutesTwoScripts() public {
        // Script A: setValue(42)
        bytes32[] memory cmdsA = new bytes32[](1);
        cmdsA[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(uint256(42));
        uint256 bitmapA = 1;

        bytes32 hashA = _computeScriptHash(cmdsA, stateA, bitmapA, bytes32(0));

        // Script B: setValue(99)
        bytes32[] memory cmdsB = new bytes32[](1);
        cmdsB[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(uint256(99));
        uint256 bitmapB = 1;

        bytes32 hashB = _computeScriptHash(cmdsB, stateB, bitmapB, bytes32(0));

        // Both scripts in a Merkle tree
        bytes32 root = _merkleRoot2(hashA, hashB);
        _setPolicy(strategist, root);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = hashB;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = hashA;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IExecutor.execute.selector, cmdsA, stateA, bitmapA, bytes32(0), proofA);
        calls[1] = abi.encodeWithSelector(IExecutor.execute.selector, cmdsB, stateB, bitmapB, bytes32(0), proofB);

        vm.prank(strategist);
        IMulticall(address(executor)).multicall(calls);

        // Last script wins (sequential execution)
        assertEq(target.lastValue(), 99);
    }

    function testMulticallResolvesCorrectSender() public {
        // Verify that msgSender() resolves to strategist, not gateway
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(77));
        uint256 bitmap = 1;

        bytes memory callData = _prepareScript(commands, state, bitmap);

        bytes[] memory calls = new bytes[](1);
        calls[0] = callData;

        vm.prank(strategist);
        IMulticall(address(executor)).multicall(calls);

        assertEq(target.lastValue(), 77);
    }

    function testMulticallFromNonStrategistReverts() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));
        uint256 bitmap = 1;

        bytes memory callData = _prepareScript(commands, state, bitmap);

        bytes[] memory calls = new bytes[](1);
        calls[0] = callData;

        // Different caller → msgSender() resolves to non-strategist → NotAStrategist
        vm.expectRevert();
        vm.prank(makeAddr("attacker"));
        IMulticall(address(executor)).multicall(calls);
    }

    function testNestedMulticallBlocked() public {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(uint256(42));

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = _prepareScript(commands, state, 1);

        bytes[] memory outerCalls = new bytes[](1);
        outerCalls[0] = abi.encodeWithSelector(IMulticall.multicall.selector, innerCalls);

        vm.expectRevert(IBatchedMulticall.AlreadyBatching.selector);
        vm.prank(strategist);
        IMulticall(address(executor)).multicall(outerCalls);
    }

    function testMulticallComposesAcrossScripts() public {
        // Script A: setValue(10)
        bytes32[] memory cmdsA = new bytes32[](1);
        cmdsA[0] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateA = new bytes[](1);
        stateA[0] = abi.encode(uint256(10));
        uint256 bitmapA = 1;

        // Script B: read getValue() into state[0], then setValue(getValue())
        // This verifies that state from script A persists on-chain for script B to read
        bytes32[] memory cmdsB = new bytes32[](2);
        cmdsB[0] = _staticCallNoInputs(WeirollTarget.getValue.selector, 0, address(target));
        cmdsB[1] = _callCommand(WeirollTarget.setValue.selector, 0, address(target));
        bytes[] memory stateB = new bytes[](1);
        stateB[0] = abi.encode(uint256(0)); // placeholder, overwritten by getValue
        uint256 bitmapB = 0; // variable state

        bytes32 hashA = _computeScriptHash(cmdsA, stateA, bitmapA, bytes32(0));
        bytes32 hashB = _computeScriptHash(cmdsB, stateB, bitmapB, bytes32(0));

        bytes32 root = _merkleRoot2(hashA, hashB);
        _setPolicy(strategist, root);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = hashB;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = hashA;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IExecutor.execute.selector, cmdsA, stateA, bitmapA, bytes32(0), proofA);
        calls[1] = abi.encodeWithSelector(IExecutor.execute.selector, cmdsB, stateB, bitmapB, bytes32(0), proofB);

        vm.prank(strategist);
        IMulticall(address(executor)).multicall(calls);

        // Script B read the value set by script A (10) and wrote it back
        assertEq(target.lastValue(), 10);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {ABICodecLib, Value, Type, Tree} from "../../../../src/misc/libraries/ABICodecLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {
    IExecutor,
    Action,
    ActionType,
    InputValue,
    SourceType
} from "../../../../src/managers/spoke/interfaces/IExecutor.sol";
import {IExecutorFactory} from "../../../../src/managers/spoke/interfaces/IExecutorFactory.sol";
import {Executor, ExecutorFactory} from "../../../../src/managers/spoke/Executor.sol";

import "forge-std/Test.sol";

contract MockTarget {
    uint256 public lastValue;

    function setValue(uint256 v) external {
        lastValue = v;
    }

    function setValueWithReceiver(uint256 v, address) external {
        lastValue = v;
    }

    function setValuePayable(uint256 v) external payable {
        lastValue = v;
    }

    function getValue() external view returns (uint256) {
        return lastValue;
    }

    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    receive() external payable {}
}

contract ExecutorTest is Test {
    using CastLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    address contractUpdater = makeAddr("contractUpdater");
    address strategist = makeAddr("strategist");
    address unauthorized = makeAddr("unauthorized");

    Executor manager;
    MockTarget target;

    function setUp() public virtual {
        manager = new Executor(POOL_A, contractUpdater);
        target = new MockTarget();
    }

    // ─── Tree/Value helpers ──────────────────────────────────────────────

    function _static() internal pure returns (Tree memory) {
        return Tree(Type.Static, new Tree[](0));
    }

    function _emptyComposite() internal pure returns (Tree memory) {
        return Tree(Type.Composite, new Tree[](0));
    }

    function _composite1(Tree memory a) internal pure returns (Tree memory) {
        Tree[] memory c = new Tree[](1);
        c[0] = a;
        return Tree(Type.Composite, c);
    }

    function _composite2(Tree memory a, Tree memory b) internal pure returns (Tree memory) {
        Tree[] memory c = new Tree[](2);
        c[0] = a;
        c[1] = b;
        return Tree(Type.Composite, c);
    }

    function _encodeTree(Tree memory tree) internal pure returns (bytes memory) {
        return tree.encodeTree();
    }

    function _fixedInput(bytes memory data) internal pure returns (InputValue memory) {
        return InputValue(SourceType.Fixed, data, new uint256[](0));
    }

    function _returnValueInput(uint256 actionIdx, uint256[] memory path) internal pure returns (InputValue memory) {
        return InputValue(SourceType.ReturnValue, abi.encode(actionIdx, path), new uint256[](0));
    }

    function _path(uint256 a) internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = a;
    }

    function _setPolicy(address who, bytes32 root) internal {
        bytes memory payload = abi.encode(who.toBytes32(), root);
        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, payload);
    }

    function _computeScriptHash(Action[] memory actions) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i; i < actions.length; i++) {
            packed = bytes.concat(packed, _computeActionHash(actions[i]));
        }
        return keccak256(packed);
    }

    function _computeActionHash(Action memory action) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                action.actionType,
                action.target,
                action.selector,
                keccak256(action.inputTree),
                keccak256(action.outputTree),
                keccak256(_encodeInputSources(action.inputs))
            )
        );
    }

    function _encodeInputSources(InputValue[] memory inputs) internal pure returns (bytes memory result) {
        for (uint256 i; i < inputs.length; i++) {
            InputValue memory iv = inputs[i];
            if (iv.children.length > 0) {
                result = bytes.concat(result, abi.encodePacked(keccak256(abi.encode(iv.children))));
            } else {
                result = bytes.concat(result, abi.encodePacked(iv.source, keccak256(iv.data)));
            }
        }
    }

    function testConstructor() public view {
        assertEq(manager.poolId().raw(), POOL_A.raw());
        assertEq(manager.contractUpdater(), contractUpdater);
    }

    function testReceiveEther() public {
        uint256 amount = 1 ether;

        (bool success,) = address(manager).call{value: amount}("");
        assertTrue(success);
        assertEq(address(manager).balance, amount);
    }
}

// ─── TrustedCall ─────────────────────────────────────────────────────────────

contract ExecutorTrustedCallFailureTests is ExecutorTest {
    using CastLib for *;

    function testInvalidPoolId() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IExecutor.InvalidPoolId.selector);
        vm.prank(contractUpdater);
        manager.trustedCall(POOL_B, SC_1, payload);
    }

    function testNotAuthorized() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IExecutor.NotAuthorized.selector);
        vm.prank(unauthorized);
        manager.trustedCall(POOL_A, SC_1, payload);
    }
}

contract ExecutorTrustedCallSuccessTests is ExecutorTest {
    using CastLib for *;

    function testTrustedCallPolicySuccess() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectEmit();
        emit IExecutor.UpdatePolicy(strategist, bytes32(0), rootHash);

        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, payload);

        assertEq(manager.policy(strategist), rootHash);
    }

    function testTrustedCallPolicyUpdate() public {
        bytes32 oldRoot = keccak256("oldRoot");
        bytes32 newRoot = keccak256("newRoot");

        _setPolicy(strategist, oldRoot);
        assertEq(manager.policy(strategist), oldRoot);

        vm.expectEmit();
        emit IExecutor.UpdatePolicy(strategist, oldRoot, newRoot);

        _setPolicy(strategist, newRoot);
        assertEq(manager.policy(strategist), newRoot);
    }

    function testTrustedCallMultipleStrategists() public {
        address strategist1 = makeAddr("strategist1");
        address strategist2 = makeAddr("strategist2");
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        _setPolicy(strategist1, root1);
        _setPolicy(strategist2, root2);

        assertEq(manager.policy(strategist1), root1);
        assertEq(manager.policy(strategist2), root2);
    }

    function testTrustedCallClearPolicy() public {
        bytes32 rootHash = keccak256("root");
        _setPolicy(strategist, rootHash);

        vm.expectEmit();
        emit IExecutor.UpdatePolicy(strategist, rootHash, bytes32(0));

        _setPolicy(strategist, bytes32(0));
        assertEq(manager.policy(strategist), bytes32(0));
    }
}

// ─── Execute ─────────────────────────────────────────────────────────────────

contract ExecutorExecuteTests is ExecutorTest {
    function testNotAStrategist() public {
        Action[] memory actions = new Action[](0);
        bytes[] memory inputs = new bytes[](0);

        vm.expectRevert(IExecutor.NotAStrategist.selector);
        vm.prank(unauthorized);
        manager.execute(actions, inputs, new bytes32[](0));
    }

    function testSingleCallAction() public {
        // setValue(uint256) with CONSTANT input
        InputValue[] memory actionInputs = new InputValue[](1);
        actionInputs[0] = _fixedInput(abi.encode(uint256(42)));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: actionInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        // Script hash is the root (empty proof → leaf == root)
        _setPolicy(strategist, _computeScriptHash(actions));

        vm.expectEmit();
        emit IExecutor.ExecuteCall(address(target), MockTarget.setValue.selector, 0);

        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));

        assertEq(target.lastValue(), 42);
    }

    function testConstantInputSecuresParam() public {
        // setValueWithReceiver(uint256, address) — address is a CONSTANT, so it's part of the script hash
        address receiver = makeAddr("receiver");

        InputValue[] memory actionInputs = new InputValue[](2);
        actionInputs[0] = _fixedInput(abi.encode(uint256(99)));
        actionInputs[1] = _fixedInput(abi.encode(receiver));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValueWithReceiver.selector,
            inputs: actionInputs,
            inputTree: _encodeTree(_composite2(_static(), _static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));

        assertEq(target.lastValue(), 99);
    }

    function testConstantInputTamperedReverts() public {
        // Authorize script with receiver = alice
        address alice = makeAddr("alice");

        InputValue[] memory authorizedInputs = new InputValue[](2);
        authorizedInputs[0] = _fixedInput(abi.encode(uint256(99)));
        authorizedInputs[1] = _fixedInput(abi.encode(alice));

        Action[] memory authorizedActions = new Action[](1);
        authorizedActions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValueWithReceiver.selector,
            inputs: authorizedInputs,
            inputTree: _encodeTree(_composite2(_static(), _static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(authorizedActions));

        // Strategist tries to substitute receiver with attacker address
        address attacker = makeAddr("attacker");

        InputValue[] memory tamperedInputs = new InputValue[](2);
        tamperedInputs[0] = _fixedInput(abi.encode(uint256(99)));
        tamperedInputs[1] = _fixedInput(abi.encode(attacker));

        Action[] memory tamperedActions = new Action[](1);
        tamperedActions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValueWithReceiver.selector,
            inputs: tamperedInputs,
            inputTree: _encodeTree(_composite2(_static(), _static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        vm.expectRevert(IExecutor.InvalidProof.selector);
        vm.prank(strategist);
        manager.execute(tamperedActions, new bytes[](0), new bytes32[](0));
    }

    function testStaticCallAction() public {
        target.setValue(777);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.StaticCall,
            target: address(target),
            selector: MockTarget.getValue.selector,
            inputs: new InputValue[](0),
            inputTree: _encodeTree(_emptyComposite()),
            outputTree: _encodeTree(_composite1(_static()))
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));
    }

    function testStaticCallThenCall() public {
        target.setValue(100);

        Action[] memory actions = new Action[](2);

        // Action 0: StaticCall getValue()
        actions[0] = Action({
            actionType: ActionType.StaticCall,
            target: address(target),
            selector: MockTarget.getValue.selector,
            inputs: new InputValue[](0),
            inputTree: _encodeTree(_emptyComposite()),
            outputTree: _encodeTree(_composite1(_static()))
        });

        // Action 1: Call setValue(result_from_action_0)
        InputValue[] memory callInputs = new InputValue[](1);
        callInputs[0] = _returnValueInput(0, _path(0));

        actions[1] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: callInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));

        assertEq(target.lastValue(), 100);
    }

    function testStaticCallThenCallComposition() public {
        // StaticCall add(10, 20) → Call setValue(result)
        Action[] memory actions = new Action[](2);

        // Action 0: StaticCall add(10, 20) → returns 30
        InputValue[] memory addInputs = new InputValue[](2);
        addInputs[0] = _fixedInput(abi.encode(uint256(10)));
        addInputs[1] = _fixedInput(abi.encode(uint256(20)));

        actions[0] = Action({
            actionType: ActionType.StaticCall,
            target: address(target),
            selector: MockTarget.add.selector,
            inputs: addInputs,
            inputTree: _encodeTree(_composite2(_static(), _static())),
            outputTree: _encodeTree(_composite1(_static()))
        });

        // Action 1: Call setValue(add_result)
        InputValue[] memory callInputs = new InputValue[](1);
        callInputs[0] = _returnValueInput(0, _path(0));

        actions[1] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: callInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));

        assertEq(target.lastValue(), 30);
    }

    function testInvalidProofReverts() public {
        bytes32 wrongRoot = keccak256("wrong");
        _setPolicy(strategist, wrongRoot);

        InputValue[] memory actionInputs = new InputValue[](1);
        actionInputs[0] = _fixedInput(abi.encode(uint256(42)));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: actionInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        vm.expectRevert(IExecutor.InvalidProof.selector);
        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));
    }

    function testInputSourceType() public {
        // Use INPUT source — value provided at call time
        InputValue[] memory actionInputs = new InputValue[](1);
        actionInputs[0] = InputValue(SourceType.Runtime, abi.encode(uint256(0)), new uint256[](0));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: actionInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        bytes[] memory userInputs = new bytes[](1);
        userInputs[0] = abi.encode(uint256(555));

        vm.prank(strategist);
        manager.execute(actions, userInputs, new bytes32[](0));

        assertEq(target.lastValue(), 555);
    }

    function testMerkleProofWithMultipleLeaves() public {
        // Two authorized scripts in a Merkle tree — test that proof verification works

        // Script A: setValue(42)
        InputValue[] memory inputsA = new InputValue[](1);
        inputsA[0] = _fixedInput(abi.encode(uint256(42)));

        Action[] memory scriptA = new Action[](1);
        scriptA[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: inputsA,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        // Script B: setValue(99)
        InputValue[] memory inputsB = new InputValue[](1);
        inputsB[0] = _fixedInput(abi.encode(uint256(99)));

        Action[] memory scriptB = new Action[](1);
        scriptB[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: inputsB,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        bytes32 leafA = _computeScriptHash(scriptA);
        bytes32 leafB = _computeScriptHash(scriptB);

        // Compute root: sorted pair hash
        bytes32 root;
        if (uint256(leafA) < uint256(leafB)) {
            root = keccak256(abi.encodePacked(leafA, leafB));
        } else {
            root = keccak256(abi.encodePacked(leafB, leafA));
        }

        _setPolicy(strategist, root);

        // Execute script A with leafB as proof sibling
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.prank(strategist);
        manager.execute(scriptA, new bytes[](0), proof);
        assertEq(target.lastValue(), 42);

        // Execute script B with leafA as proof sibling
        proof[0] = leafA;

        vm.prank(strategist);
        manager.execute(scriptB, new bytes[](0), proof);
        assertEq(target.lastValue(), 99);
    }

    function testForwardReferenceReverts() public {
        // Action 0 tries to reference action 1's result (forward reference)
        InputValue[] memory badInputs = new InputValue[](1);
        badInputs[0] = _returnValueInput(1, _path(0)); // references action 1 from action 0

        Action[] memory actions = new Action[](2);
        actions[0] = Action({
            actionType: ActionType.Call,
            target: address(target),
            selector: MockTarget.setValue.selector,
            inputs: badInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });
        actions[1] = Action({
            actionType: ActionType.StaticCall,
            target: address(target),
            selector: MockTarget.getValue.selector,
            inputs: new InputValue[](0),
            inputTree: _encodeTree(_emptyComposite()),
            outputTree: _encodeTree(_composite1(_static()))
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.expectRevert(IExecutor.InvalidResultReference.selector);
        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));
    }

    function testValueCallAction() public {
        // Fund executor with ETH
        vm.deal(address(manager), 1 ether);

        // inputs[0] = ETH amount (Fixed), inputs[1] = function arg (Fixed)
        InputValue[] memory actionInputs = new InputValue[](2);
        actionInputs[0] = _fixedInput(abi.encode(uint256(0.5 ether)));
        actionInputs[1] = _fixedInput(abi.encode(uint256(123)));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.ValueCall,
            target: address(target),
            selector: MockTarget.setValuePayable.selector,
            inputs: actionInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.expectEmit();
        emit IExecutor.ExecuteCall(address(target), MockTarget.setValuePayable.selector, 0.5 ether);

        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));

        assertEq(target.lastValue(), 123);
        assertEq(address(target).balance, 0.5 ether);
        assertEq(address(manager).balance, 0.5 ether);
    }

    function testValueCallInsufficientBalance() public {
        // Don't fund executor — should revert
        InputValue[] memory actionInputs = new InputValue[](2);
        actionInputs[0] = _fixedInput(abi.encode(uint256(1 ether)));
        actionInputs[1] = _fixedInput(abi.encode(uint256(42)));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            actionType: ActionType.ValueCall,
            target: address(target),
            selector: MockTarget.setValuePayable.selector,
            inputs: actionInputs,
            inputTree: _encodeTree(_composite1(_static())),
            outputTree: _encodeTree(_emptyComposite())
        });

        _setPolicy(strategist, _computeScriptHash(actions));

        vm.expectRevert(IExecutor.InsufficientBalance.selector);
        vm.prank(strategist);
        manager.execute(actions, new bytes[](0), new bytes32[](0));
    }
}

// ─── Factory ─────────────────────────────────────────────────────────────────

contract ExecutorFactoryTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address contractUpdater = makeAddr("contractUpdater");
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    ExecutorFactory factory;

    function setUp() public virtual {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        factory = new ExecutorFactory(contractUpdater, balanceSheet);
    }

    function testConstructor() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.balanceSheet()), address(balanceSheet));
    }
}

contract ExecutorFactoryNewManagerTest is ExecutorFactoryTest {
    function testNewManagerSuccess() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IExecutor mgr = factory.newExecutor(POOL_A);
        Executor concreteMgr = Executor(payable(address(mgr)));

        assertEq(concreteMgr.poolId().raw(), POOL_A.raw());
        assertEq(concreteMgr.contractUpdater(), contractUpdater);
    }

    function testNewManagerInvalidPoolId() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_B), abi.encode(false));

        vm.expectRevert(IExecutorFactory.InvalidPoolId.selector);
        factory.newExecutor(POOL_B);
    }

    function testNewManagerDeterministic() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        factory.newExecutor(POOL_A);

        // Second call should revert because CREATE2 with same salt fails
        vm.expectRevert();
        factory.newExecutor(POOL_A);
    }

    function testNewManagerEventEmission() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        vm.recordLogs();
        IExecutor mgr = factory.newExecutor(POOL_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("DeployExecutor(uint64,address)"));
        assertEq(uint256(logs[0].topics[1]), POOL_A.raw());
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(mgr));
    }
}

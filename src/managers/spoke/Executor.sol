// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IExecutorFactory} from "./interfaces/IExecutorFactory.sol";
import {IExecutor, Action, ActionType, InputValue, SourceType} from "./interfaces/IExecutor.sol";

import {ABICodecLib, Value, Tree, decodeTree} from "../../misc/libraries/ABICodecLib.sol";
import {MerkleProofLib} from "../../misc/libraries/MerkleProofLib.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {Multicall} from "../../misc/Multicall.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  Executor
/// @notice Generic execution engine with script-level Merkle authorization and composable StaticCall → Call chaining.
contract Executor is Multicall, IExecutor, ITrustedContractUpdate {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable contractUpdater;

    mapping(address strategist => bytes32 root) public policy;

    constructor(PoolId poolId_, address contractUpdater_) {
        poolId = poolId_;
        contractUpdater = contractUpdater_;
    }

    receive() external payable {}

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(
        PoolId poolId_,
        ShareClassId,
        /* scId */
        bytes memory payload
    )
        external
    {
        require(poolId == poolId_, InvalidPoolId());
        require(msg.sender == contractUpdater, NotAuthorized());

        (bytes32 who, bytes32 what) = abi.decode(payload, (bytes32, bytes32));
        address strategist = who.toAddress();

        bytes32 oldRoot = policy[strategist];
        policy[strategist] = what;

        emit UpdatePolicy(strategist, oldRoot, what);
    }

    //----------------------------------------------------------------------------------------------
    // Strategist actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IExecutor
    function execute(Action[] calldata actions, bytes[] calldata inputs, bytes32[] calldata proof) external payable {
        bytes32 root = policy[msg.sender];
        require(root != bytes32(0), NotAStrategist());

        require(MerkleProofLib.verify(proof, root, _computeScriptHash(actions)), InvalidProof());

        Value[] memory responses = new Value[](actions.length);
        Tree[] memory outTrees = new Tree[](actions.length);
        for (uint256 i; i < actions.length; i++) {
            _executeAction(i, actions[i], inputs, responses, outTrees);
        }
    }

    function _executeAction(
        uint256 i,
        Action calldata action,
        bytes[] calldata inputs,
        Value[] memory responses,
        Tree[] memory outTrees
    ) internal {
        Tree memory inputTree = decodeTree(action.inputTree);
        Tree memory outputTree = decodeTree(action.outputTree);

        uint256 inputOffset;
        uint256 ethValue;
        if (action.actionType == ActionType.ValueCall) {
            Value memory ethInput = _resolveInput(i, 0, action.inputs, inputs, responses, outTrees);
            ethValue = abi.decode(ethInput.data, (uint256));
            inputOffset = 1;
        }

        bytes memory callData = abi.encodePacked(
            action.selector,
            ABICodecLib.encode(
                _buildInput(i, action.inputs, inputTree, inputs, responses, outTrees, inputOffset), inputTree
            )
        );

        bytes memory ret;
        bool ok;
        if (action.actionType == ActionType.StaticCall) {
            (ok, ret) = action.target.staticcall(callData);
            require(ok, CallFailed());
        } else {
            require(address(this).balance >= ethValue, InsufficientBalance());
            (ok, ret) = action.target.call{value: ethValue}(callData);
            require(ok, WrappedError(action.target, action.selector, ret, abi.encodeWithSelector(CallFailed.selector)));

            emit ExecuteCall(action.target, action.selector, ethValue);
        }

        responses[i] = ABICodecLib.decode(ret, outputTree);
        outTrees[i] = outputTree;
    }

    //----------------------------------------------------------------------------------------------
    // Script hashing
    //----------------------------------------------------------------------------------------------

    function _computeScriptHash(Action[] calldata actions) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](actions.length);
        for (uint256 i; i < actions.length; i++) {
            hashes[i] = _computeActionHash(actions[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _computeActionHash(Action calldata action) internal pure returns (bytes32) {
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

    function _encodeInputSources(InputValue[] calldata inputs) internal pure returns (bytes memory result) {
        for (uint256 i; i < inputs.length; i++) {
            InputValue calldata iv = inputs[i];
            if (iv.children.length > 0) {
                result = bytes.concat(result, abi.encodePacked(keccak256(abi.encode(iv.children))));
            } else {
                result = bytes.concat(result, abi.encodePacked(iv.source, keccak256(iv.data)));
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Input resolution
    //----------------------------------------------------------------------------------------------

    function _buildInput(
        uint256 currentAction,
        InputValue[] calldata actionInputs,
        Tree memory inputTree,
        bytes[] calldata userInputs,
        Value[] memory responses,
        Tree[] memory outTrees,
        uint256 inputOffset
    ) internal pure returns (Value memory) {
        uint256 n = inputTree.children.length;
        require(actionInputs.length >= n + inputOffset, InputLengthMismatch());
        Value[] memory topChildren = new Value[](n);
        for (uint256 i; i < n; i++) {
            topChildren[i] =
                _resolveInput(currentAction, i + inputOffset, actionInputs, userInputs, responses, outTrees);
        }
        return Value("", topChildren);
    }

    function _resolveInput(
        uint256 currentAction,
        uint256 index,
        InputValue[] calldata actionInputs,
        bytes[] calldata userInputs,
        Value[] memory responses,
        Tree[] memory outTrees
    ) internal pure returns (Value memory) {
        InputValue calldata iv = actionInputs[index];

        // Composite: recursively resolve children
        if (iv.children.length > 0) {
            Value[] memory children = new Value[](iv.children.length);
            for (uint256 j; j < iv.children.length; j++) {
                children[j] =
                    _resolveInput(currentAction, iv.children[j], actionInputs, userInputs, responses, outTrees);
            }
            return Value("", children);
        }

        if (iv.source == SourceType.Fixed) {
            return Value(iv.data, new Value[](0));
        }

        if (iv.source == SourceType.Runtime) {
            uint256 idx = abi.decode(iv.data, (uint256));
            return Value(userInputs[idx], new Value[](0));
        }

        // ReturnValue
        (uint256 actionIdx, uint256[] memory path) = abi.decode(iv.data, (uint256, uint256[]));
        require(actionIdx < currentAction, InvalidResultReference());
        (Value memory v,) = ABICodecLib.traverse(responses[actionIdx], outTrees[actionIdx], path);
        return v;
    }
}

contract ExecutorFactory is IExecutorFactory {
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc IExecutorFactory
    function newExecutor(PoolId poolId) external returns (IExecutor) {
        require(balanceSheet.spoke().isPoolActive(poolId), InvalidPoolId());

        Executor executor = new Executor{salt: bytes32(uint256(poolId.raw()))}(poolId, contractUpdater);

        emit DeployExecutor(poolId, address(executor));
        return IExecutor(address(executor));
    }
}

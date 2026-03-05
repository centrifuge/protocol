// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Multicall} from "../src/misc/Multicall.sol";
import {CastLib} from "../src/misc/libraries/CastLib.sol";
import {MerkleProofLib} from "../src/misc/libraries/MerkleProofLib.sol";

import {PoolId} from "../src/core/types/PoolId.sol";
import {ShareClassId} from "../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IExecutor} from "../src/managers/spoke/interfaces/IExecutor.sol";
import {IExecutorFactory} from "../src/managers/spoke/interfaces/IExecutorFactory.sol";

import {VM} from "enso-weiroll/VM.sol";

/// @title  Executor
/// @notice Weiroll VM-based execution engine with script-level Merkle authorization and a state bitmap
///         for selectively fixing hub-manager-approved state elements.
/// @dev    Compiled with `via_ir` to handle the weiroll VM's stack depth. The VM only supports
///         CALL, STATICCALL, and VALUECALL to external targets (never DELEGATECALL), so the
///         Executor's storage (policy mapping) cannot be overwritten by target contracts.
contract Executor is Multicall, VM, IExecutor {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable contractUpdater;

    mapping(address strategist => bytes32 root) public policy;

    /// @dev Tracks the strategist whose `execute()` is currently running. Set to address(0) outside execution.
    address private transient _activeStrategist;

    /// @dev Prevents nested callbacks (flash-within-flash).
    bool private transient _inCallback;

    constructor(PoolId poolId_, address contractUpdater_) {
        poolId = poolId_;
        contractUpdater = contractUpdater_;
    }

    receive() external payable {}

    // ──────────────────────────────────────────────────────────────────────────
    // Owner actions
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Update the strategist policy root via the ContractUpdater.
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

    // ──────────────────────────────────────────────────────────────────────────
    // Strategist actions
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IExecutor
    function execute(bytes32[] calldata commands, bytes[] calldata state, uint256 stateBitmap, bytes32[] calldata proof)
        external
        payable
        protected
    {
        bytes32 root = policy[msg.sender];
        require(root != bytes32(0), NotAStrategist());
        require(state.length <= 256, StateLengthOverflow());

        bytes32 scriptHash = _computeScriptHash(commands, state, stateBitmap);
        require(MerkleProofLib.verify(proof, root, scriptHash), InvalidProof());

        // Copy calldata state to memory — weiroll mutates state in-place
        bytes[] memory mState = new bytes[](state.length);
        for (uint256 i; i < state.length; i++) {
            mState[i] = state[i];
        }

        _activeStrategist = msg.sender;
        _execute(commands, mState);
        _activeStrategist = address(0);

        emit ExecuteScript(msg.sender, scriptHash);
    }

    /// @inheritdoc IExecutor
    function executeCallback(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint256 stateBitmap,
        bytes32[] calldata proof
    ) external {
        require(_activeStrategist != address(0), NotInExecution());
        require(!_inCallback, NestedCallback());
        require(state.length <= 256, StateLengthOverflow());

        bytes32 scriptHash = _computeScriptHash(commands, state, stateBitmap);
        require(MerkleProofLib.verify(proof, policy[_activeStrategist], scriptHash), InvalidProof());

        _inCallback = true;

        bytes[] memory mState = new bytes[](state.length);
        for (uint256 i; i < state.length; i++) {
            mState[i] = state[i];
        }
        _execute(commands, mState);

        _inCallback = false;

        emit ExecuteScript(_activeStrategist, scriptHash);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Script hashing
    // ──────────────────────────────────────────────────────────────────────────

    function _computeScriptHash(bytes32[] calldata commands, bytes[] calldata state, uint256 stateBitmap)
        internal
        pure
        returns (bytes32)
    {
        uint256 count;
        for (uint256 i; i < state.length; i++) {
            if (stateBitmap & (1 << i) != 0) count++;
        }

        bytes32[] memory hashes = new bytes32[](count);
        uint256 j;
        for (uint256 i; i < state.length; i++) {
            if (stateBitmap & (1 << i) != 0) {
                hashes[j++] = keccak256(state[i]);
            }
        }

        return keccak256(
            abi.encodePacked(keccak256(abi.encodePacked(commands)), keccak256(abi.encodePacked(hashes)), stateBitmap)
        );
    }
}

/// @title  ExecutorFactory
/// @notice Deploys pool-specific Executor instances deterministically via CREATE2.
contract ExecutorFactory is IExecutorFactory {
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    mapping(PoolId poolId => address) public executors;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc IExecutorFactory
    function newExecutor(PoolId poolId) external returns (IExecutor) {
        require(balanceSheet.spoke().isPoolActive(poolId), InvalidPoolId());

        Executor executor = new Executor{salt: bytes32(uint256(poolId.raw()))}(poolId, contractUpdater);
        executors[poolId] = address(executor);

        emit DeployExecutor(poolId, address(executor));
        return IExecutor(address(executor));
    }
}

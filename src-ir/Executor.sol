// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../src/misc/libraries/CastLib.sol";
import {MerkleProofLib} from "../src/misc/libraries/MerkleProofLib.sol";
import {TransientArrayLib} from "../src/misc/libraries/TransientArrayLib.sol";

import {PoolId} from "../src/core/types/PoolId.sol";
import {ShareClassId} from "../src/core/types/ShareClassId.sol";
import {IGateway} from "../src/core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../src/core/utils/BatchedMulticall.sol";
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
contract Executor is BatchedMulticall, VM, IExecutor {
    using CastLib for *;

    bytes32 private constant CALLBACK_HASHES_SLOT = bytes32(uint256(keccak256("executor.callbackHashes")) - 1);
    bytes32 private constant CALLBACK_CALLERS_SLOT = bytes32(uint256(keccak256("executor.callbackCallers")) - 1);

    PoolId public immutable poolId;
    address public immutable contractUpdater;

    mapping(address strategist => bytes32 root) public policy;

    address public transient activeStrategist;
    uint256 public transient callbackIdx;

    constructor(PoolId poolId_, address contractUpdater_, IGateway gateway_) BatchedMulticall(gateway_) {
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
        bytes calldata payload
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
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint128 stateBitmap,
        bytes32[] calldata callbackHashes,
        address[] calldata callbackCallers,
        bytes32[] calldata proof
    ) external payable {
        bytes32 root = policy[msgSender()];
        require(root != bytes32(0), NotAStrategist());
        require(state.length <= 128, StateLengthOverflow());
        require(activeStrategist == address(0), AlreadyExecuting());
        require(callbackHashes.length == callbackCallers.length, CallbackLengthMismatch());

        bytes32 scriptHash = computeScriptHash(commands, state, stateBitmap, callbackHashes, callbackCallers);
        require(MerkleProofLib.verify(proof, root, scriptHash), InvalidProof());

        activeStrategist = msgSender();
        for (uint256 i; i < callbackHashes.length; i++) {
            TransientArrayLib.push(CALLBACK_HASHES_SLOT, callbackHashes[i]);
            TransientArrayLib.push(CALLBACK_CALLERS_SLOT, callbackCallers[i]);
        }

        _execute(commands, _copyState(state));
        require(callbackIdx == TransientArrayLib.length(CALLBACK_HASHES_SLOT), UnconsumedCallbacks());

        callbackIdx = 0;
        activeStrategist = address(0);
        TransientArrayLib.clear(CALLBACK_HASHES_SLOT);
        TransientArrayLib.clear(CALLBACK_CALLERS_SLOT);

        emit ExecuteScript(msgSender(), scriptHash);
    }

    /// @inheritdoc IExecutor
    function executeCallback(bytes32[] calldata commands, bytes[] calldata state, uint128 stateBitmap) external {
        require(state.length <= 128, StateLengthOverflow());
        require(msg.sender != address(this), SelfCallForbidden());
        require(activeStrategist != address(0), NotInExecution());

        uint256 idx = callbackIdx;
        require(idx < TransientArrayLib.length(CALLBACK_HASHES_SLOT), CallbackExhausted());

        require(msg.sender == TransientArrayLib.atAddress(CALLBACK_CALLERS_SLOT, idx), InvalidCallbackCaller());

        bytes32 expected = TransientArrayLib.at(CALLBACK_HASHES_SLOT, idx);
        bytes32 scriptHash = computeScriptHash(commands, state, stateBitmap, new bytes32[](0), new address[](0));
        require(scriptHash == expected, InvalidCallback());

        callbackIdx = idx + 1;
        _execute(commands, _copyState(state));

        emit ExecuteCallback(activeStrategist, scriptHash);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────────────

    function computeScriptHash(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint128 stateBitmap,
        bytes32[] memory callbackHashes,
        address[] memory callbackCallers
    ) public pure returns (bytes32) {
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
            abi.encodePacked(
                keccak256(abi.encodePacked(commands)),
                keccak256(abi.encodePacked(hashes)),
                stateBitmap,
                state.length,
                keccak256(abi.encodePacked(callbackHashes)),
                keccak256(abi.encodePacked(callbackCallers))
            )
        );
    }

    /// @dev Copy calldata state to memory, since weiroll mutates state in-place.
    function _copyState(bytes[] calldata state) internal pure returns (bytes[] memory mState) {
        mState = new bytes[](state.length);
        for (uint256 i; i < state.length; i++) {
            mState[i] = state[i];
        }
    }

}

/// @title  ExecutorFactory
/// @notice Deploys pool-specific Executor instances deterministically via CREATE2.
contract ExecutorFactory is IExecutorFactory {
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;
    IGateway public immutable gateway;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_, IGateway gateway_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
        gateway = gateway_;
    }

    /// @inheritdoc IExecutorFactory
    function newExecutor(PoolId poolId) external returns (IExecutor) {
        require(balanceSheet.spoke().isPoolActive(poolId), InvalidPoolId());

        Executor executor = new Executor{salt: bytes32(uint256(poolId.raw()))}(poolId, contractUpdater, gateway);

        emit DeployExecutor(poolId, address(executor));
        return IExecutor(address(executor));
    }
}

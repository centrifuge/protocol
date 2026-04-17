// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.28;

import {CastLib} from "../src/misc/libraries/CastLib.sol";
import {MerkleProofLib} from "../src/misc/libraries/MerkleProofLib.sol";
import {TransientArrayLib} from "../src/misc/libraries/TransientArrayLib.sol";

import {PoolId} from "../src/core/types/PoolId.sol";
import {ShareClassId} from "../src/core/types/ShareClassId.sol";
import {IGateway} from "../src/core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../src/core/utils/BatchedMulticall.sol";
import {IBalanceSheet} from "../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IOnchainPM} from "../src/managers/spoke/interfaces/IOnchainPM.sol";
import {IOnchainPMFactory} from "../src/managers/spoke/interfaces/IOnchainPMFactory.sol";

import {VM} from "enso-weiroll/VM.sol";

/// @title  Onchain Portfolio Manager
/// @notice Weiroll VM-based execution engine with script-level Merkle authorization and a state bitmap
///         for selectively fixing hub-manager-approved state elements.
/// @dev    Compiled with `via_ir` to handle the weiroll VM's stack depth. The VM only supports
///         CALL, STATICCALL, and VALUECALL to external targets (never DELEGATECALL), so the
///         OnchainPM's storage (policy mapping) cannot be overwritten by target contracts.
contract OnchainPM is BatchedMulticall, VM, IOnchainPM {
    using CastLib for *;

    bytes32 private constant CALLBACK_HASHES_SLOT = bytes32(uint256(keccak256("onchainPM.callbackHashes")) - 1);
    bytes32 private constant CALLBACK_CALLERS_SLOT = bytes32(uint256(keccak256("onchainPM.callbackCallers")) - 1);

    PoolId public immutable poolId;
    address public immutable contractUpdater;

    mapping(address strategist => bytes32 root) public policy;

    uint256 public transient callbackIdx;
    address public transient activeStrategist;

    constructor(PoolId poolId_, address contractUpdater_, IGateway gateway_) BatchedMulticall(gateway_) {
        poolId = poolId_;
        contractUpdater = contractUpdater_;
    }

    receive() external payable {}

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @notice Update the strategist policy root via the ContractUpdater.
    function trustedCall(PoolId poolId_, ShareClassId, bytes calldata payload) external {
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

    /// @inheritdoc IOnchainPM
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint128 stateBitmap,
        IOnchainPM.Callback[] calldata callbacks,
        bytes32[] calldata proof
    ) external payable {
        bytes32 root = policy[msgSender()];
        require(root != bytes32(0), NotAStrategist());
        require(state.length <= 128, StateLengthOverflow());
        require(activeStrategist == address(0), AlreadyExecuting());

        bytes32 scriptHash = computeScriptHash(commands, state, stateBitmap, callbacks);
        require(MerkleProofLib.verify(proof, root, scriptHash), InvalidProof());

        activeStrategist = msgSender();
        for (uint256 i; i < callbacks.length; i++) {
            TransientArrayLib.push(CALLBACK_HASHES_SLOT, callbacks[i].hash);
            TransientArrayLib.push(CALLBACK_CALLERS_SLOT, callbacks[i].caller);
        }

        bytes[] memory mState = _copyState(state);
        _execute(commands, mState);
        require(callbackIdx == TransientArrayLib.length(CALLBACK_HASHES_SLOT), UnconsumedCallbacks());

        callbackIdx = 0;
        activeStrategist = address(0);
        TransientArrayLib.clear(CALLBACK_HASHES_SLOT);
        TransientArrayLib.clear(CALLBACK_CALLERS_SLOT);

        emit ExecuteScript(msgSender(), scriptHash);
    }

    /// @inheritdoc IOnchainPM
    function executeCallback(bytes32[] calldata commands, bytes[] calldata state, uint128 stateBitmap) external {
        require(state.length <= 128, StateLengthOverflow());
        require(msg.sender != address(this), SelfCallForbidden());
        require(activeStrategist != address(0), NotInExecution());

        uint256 idx = callbackIdx;
        require(idx < TransientArrayLib.length(CALLBACK_HASHES_SLOT), CallbackExhausted());
        require(msg.sender == TransientArrayLib.atAddress(CALLBACK_CALLERS_SLOT, idx), InvalidCallbackCaller());

        bytes32 expected = TransientArrayLib.at(CALLBACK_HASHES_SLOT, idx);
        bytes32 scriptHash = computeScriptHash(commands, state, stateBitmap, new IOnchainPM.Callback[](0));
        require(scriptHash == expected, InvalidCallback());

        callbackIdx = idx + 1;
        bytes[] memory mState = _copyState(state);
        _execute(commands, mState);

        emit ExecuteCallback(activeStrategist, scriptHash);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function computeScriptHash(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint128 stateBitmap,
        IOnchainPM.Callback[] memory callbacks
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                keccak256(abi.encodePacked(commands)),
                _hashBitmapSlots(state, stateBitmap),
                stateBitmap,
                state.length,
                keccak256(abi.encode(callbacks))
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

    /// @dev Hash all state slots whose bit is set in `bitmap`. Returns keccak256("") when bitmap is zero.
    function _hashBitmapSlots(bytes[] memory state, uint128 bitmap) internal pure returns (bytes32) {
        require(bitmap >> state.length == 0, InvalidBitmap());

        uint256 count;
        for (uint256 i; i < state.length; i++) {
            if (bitmap & (1 << i) != 0) count++;
        }

        bytes32[] memory hashes = new bytes32[](count);
        uint256 j;
        for (uint256 i; i < state.length; i++) {
            if (bitmap & (1 << i) != 0) hashes[j++] = keccak256(state[i]);
        }

        return keccak256(abi.encodePacked(hashes));
    }
}

/// @title  Onchain Portfolio Manager Factory
/// @notice Deploys pool-specific OnchainPM instances deterministically via CREATE2.
contract OnchainPMFactory is IOnchainPMFactory {
    IGateway public immutable gateway;
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_, IGateway gateway_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
        gateway = gateway_;
    }

    /// @inheritdoc IOnchainPMFactory
    function newOnchainPM(PoolId poolId) external returns (IOnchainPM) {
        require(balanceSheet.spoke().isPoolActive(poolId), InvalidPoolId());

        OnchainPM onchainPM = new OnchainPM{salt: bytes32(uint256(poolId.raw()))}(poolId, contractUpdater, gateway);

        emit DeployOnchainPM(poolId, address(onchainPM));
        return IOnchainPM(address(onchainPM));
    }

    /// @inheritdoc IOnchainPMFactory
    function getAddress(PoolId poolId) external view returns (address) {
        bytes32 salt = bytes32(uint256(poolId.raw()));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(OnchainPM).creationCode, abi.encode(poolId, contractUpdater, gateway)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}

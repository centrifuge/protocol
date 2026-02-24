// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWeirollExecutorFactory} from "./interfaces/IWeirollExecutorFactory.sol";
import {IWeirollExecutor} from "./interfaces/IWeirollExecutor.sol";

import {VM} from "enso-weiroll/VM.sol";
import {MerkleProofLib} from "../../misc/libraries/MerkleProofLib.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {Multicall} from "../../misc/Multicall.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  WeirollExecutor
/// @notice Weiroll VM-based execution engine with script-level Merkle authorization and a state bitmap
///         for selectively fixing governance-approved state elements.
contract WeirollExecutor is Multicall, VM, IWeirollExecutor, ITrustedContractUpdate {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable contractUpdater;

    mapping(address strategist => bytes32 root) public policy;

    constructor(PoolId poolId_, address contractUpdater_) {
        poolId = poolId_;
        contractUpdater = contractUpdater_;
    }

    receive() external payable {}

    // ──────────────────────────────────────────────────────────────────────────
    // Owner actions
    // ──────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId_, ShareClassId, /* scId */ bytes memory payload) external {
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

    /// @inheritdoc IWeirollExecutor
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint256 stateBitmap,
        bytes32[] calldata proof
    ) external payable {
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

        _execute(commands, mState);

        emit ExecuteScript(msg.sender, scriptHash);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Script hashing
    // ──────────────────────────────────────────────────────────────────────────

    function _computeScriptHash(bytes32[] calldata commands, bytes[] calldata state, uint256 stateBitmap)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(keccak256(abi.encodePacked(commands)), _hashFixedState(state, stateBitmap), stateBitmap)
        );
    }

    function _hashFixedState(bytes[] calldata state, uint256 stateBitmap) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i; i < state.length; i++) {
            if (stateBitmap & (1 << i) != 0) {
                packed = bytes.concat(packed, keccak256(state[i]));
            }
        }
        return keccak256(packed);
    }
}

/// @title  WeirollExecutorFactory
/// @notice Deploys pool-specific WeirollExecutor instances deterministically via CREATE2.
contract WeirollExecutorFactory is IWeirollExecutorFactory {
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc IWeirollExecutorFactory
    function newWeirollExecutor(PoolId poolId) external returns (IWeirollExecutor) {
        require(balanceSheet.spoke().isPoolActive(poolId), InvalidPoolId());

        WeirollExecutor executor =
            new WeirollExecutor{salt: bytes32(uint256(poolId.raw()))}(poolId, contractUpdater);

        emit DeployWeirollExecutor(poolId, address(executor));
        return IWeirollExecutor(address(executor));
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IBatchedMulticall} from "../../../core/utils/interfaces/IBatchedMulticall.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

interface IOnchainPM is IBatchedMulticall, ITrustedContractUpdate {
    /// @notice A pre-committed callback: the script hash the outer script expects, and the address
    ///         that must call executeCallback() to satisfy it.
    struct Callback {
        bytes32 hash;
        address caller;
    }

    event UpdatePolicy(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event ExecuteScript(address indexed strategist, bytes32 scriptHash);
    event ExecuteCallback(address indexed strategist, bytes32 scriptHash);

    error NotAStrategist();
    error InvalidProof();
    error InvalidCallback();
    error InvalidCallbackCaller();
    error CallbackExhausted();
    error UnconsumedCallbacks();
    error SelfCallForbidden();
    error InvalidPoolId();
    error NotAuthorized();
    error StateLengthOverflow();
    error NotInExecution();
    error AlreadyExecuting();

    function poolId() external view returns (PoolId);
    function contractUpdater() external view returns (address);
    function policy(address strategist) external view returns (bytes32);
    function activeStrategist() external view returns (address);
    function callbackIdx() external view returns (uint256);

    /// @notice Execute a weiroll script authorized by a Merkle proof.
    /// @param commands     Weiroll command bytes (selector + flags + indices + output + target).
    /// @param state        Weiroll state array.
    /// @param stateBitmap  Bit `i` set means `state[i]` is governance-approved (included in script hash).
    /// @param callbacks    Pre-committed (hash, caller) pairs consumed by executeCallback in order.
    /// @param proof        Merkle proof siblings for the script hash leaf.
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint128 stateBitmap,
        Callback[] calldata callbacks,
        bytes32[] calldata proof
    ) external payable;

    /// @notice Execute a callback script during an active `execute()`. Bound to the outer script
    ///         via a pre-committed hash — no separate Merkle proof needed.
    /// @dev    Guarded by `activeStrategist != 0` and the pre-committed caller check.
    /// @param commands     Weiroll command bytes for the callback script.
    /// @param state        Weiroll state array for the callback script.
    /// @param stateBitmap  State bitmap: set bits are included in hash.
    function executeCallback(bytes32[] calldata commands, bytes[] calldata state, uint128 stateBitmap) external;
}

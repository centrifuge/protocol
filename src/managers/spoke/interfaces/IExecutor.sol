// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IBatchedMulticall} from "../../../core/utils/interfaces/IBatchedMulticall.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

interface IExecutor is IBatchedMulticall, ITrustedContractUpdate {
    event UpdatePolicy(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event ExecuteScript(address indexed strategist, bytes32 scriptHash);

    error NotAStrategist();
    error InvalidProof();
    error InvalidCallback();
    error InvalidPoolId();
    error NotAuthorized();
    error StateLengthOverflow();
    error NotInExecution();
    error NestedCallback();

    function poolId() external view returns (PoolId);
    function contractUpdater() external view returns (address);
    function policy(address strategist) external view returns (bytes32);
    function inCallback() external view returns (bool);
    function activeStrategist() external view returns (address);
    function expectedCallback() external view returns (bytes32);

    /// @notice Execute a weiroll script authorized by a Merkle proof.
    /// @param commands     Weiroll command bytes (selector + flags + indices + output + target).
    /// @param state        Weiroll state array — elements with their bitmap bit set are fixed (hashed).
    /// @param stateBitmap  Bit `i` set means `state[i]` is governance-approved and included in the script hash.
    /// @param callbackHash Script hash of the bound callback, or bytes32(0) if no callback is used.
    /// @param proof        Merkle proof siblings for the script hash leaf.
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint256 stateBitmap,
        bytes32 callbackHash,
        bytes32[] calldata proof
    ) external payable;

    /// @notice Execute a callback script during an active `execute()`. Bound to the outer script
    ///         via `callbackHash` — no separate Merkle proof needed.
    /// @dev    No `protected` modifier — guarded by `activeStrategist != 0` and `!inCallback` instead.
    /// @param commands     Weiroll command bytes for the callback script.
    /// @param state        Weiroll state array for the callback script.
    /// @param stateBitmap  State bitmap for the callback script.
    function executeCallback(bytes32[] calldata commands, bytes[] calldata state, uint256 stateBitmap) external;
}

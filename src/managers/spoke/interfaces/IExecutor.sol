// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC7751} from "../../../misc/interfaces/IERC7751.sol";
import {IMulticall} from "../../../misc/interfaces/IMulticall.sol";

/// @notice How an action is executed.
enum ActionType {
    /// @dev staticcall, no state change, read on-chain data for subsequent actions
    StaticCall,
    /// @dev call, state-changing call, no ETH sent
    Call,
    /// @dev call with ETH, inputs[0] resolves to the ETH amount, remaining inputs map to function arguments
    ValueCall
}

/// @notice Where a leaf input value comes from. Ignored when children is non-empty (composite node).
enum SourceType {
    Fixed,
    Runtime,
    ReturnValue
}

/// @notice A single input to an action.
/// @dev    children.length == 0 → leaf, resolved via source + data.
///         children.length > 0  → composite, recursively resolves children indices from the action's inputs array.
struct InputValue {
    SourceType source;
    bytes data;
    uint256[] children;
}

struct Action {
    ActionType actionType;
    address target;
    bytes4 selector;
    InputValue[] inputs;
    bytes inputTree;
    bytes outputTree;
}

interface IExecutor is IERC7751, IMulticall {
    event UpdatePolicy(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event ExecuteCall(address indexed target, bytes4 indexed selector, uint256 value);

    error NotAStrategist();
    error CallFailed();
    error InvalidProof();
    error InvalidPoolId();
    error NotAuthorized();
    error InsufficientBalance();
    error InputLengthMismatch();
    error InvalidResultReference();

    function execute(Action[] calldata actions, bytes[] calldata inputs, bytes32[] calldata proof) external payable;
}

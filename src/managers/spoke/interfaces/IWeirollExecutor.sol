// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMulticall} from "../../../misc/interfaces/IMulticall.sol";

interface IWeirollExecutor is IMulticall {
    event UpdatePolicy(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event ExecuteScript(address indexed strategist, bytes32 scriptHash);

    error NotAStrategist();
    error InvalidProof();
    error InvalidPoolId();
    error NotAuthorized();
    error StateLengthOverflow();

    /// @notice Execute a weiroll script authorized by a Merkle proof.
    /// @param commands  Weiroll command bytes (selector + flags + indices + output + target).
    /// @param state     Weiroll state array — elements with their bitmap bit set are fixed (hashed).
    /// @param stateBitmap  Bit `i` set means `state[i]` is governance-approved and included in the script hash.
    /// @param proof     Merkle proof siblings for the script hash leaf.
    function execute(
        bytes32[] calldata commands,
        bytes[] calldata state,
        uint256 stateBitmap,
        bytes32[] calldata proof
    ) external payable;
}

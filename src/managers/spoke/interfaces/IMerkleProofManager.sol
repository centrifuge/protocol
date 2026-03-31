// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";

struct Call {
    address decoder;
    address target;
    bytes targetData;
    uint256 value;
    bytes32[] proof;
}

struct PolicyLeaf {
    address decoder;
    address target;
    bool valueNonZero;
    bytes4 selector;
    bytes addresses;
}

interface IERC7751 {
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
}

interface IMerkleProofManager is IERC7751 {
    event UpdatePolicy(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event ExecuteCall(address indexed target, bytes4 indexed selector, bytes targetData, uint256 value);

    error InsufficientBalance();
    error DecodingFailed();
    error CallFailed();
    error InvalidProofLength();
    error InvalidTargetDataLength();
    error InvalidValuesLength();
    error InvalidDecodersLength();
    error InvalidProof(PolicyLeaf leaf, bytes32[] proof);
    error NotAStrategist();
    error InvalidPoolId();
    error NotAuthorized();

    /// @notice Pool identifier this manager is scoped to
    function poolId() external view returns (PoolId);

    /// @notice Address authorized to update strategist policies via trusted cross-chain calls
    function contractUpdater() external view returns (address);

    /// @notice Merkle root defining the set of permitted operations for a strategist
    /// @param strategist The strategist address
    function policy(address strategist) external view returns (bytes32);

    /// @notice Execute a series of calls.
    function execute(Call[] calldata calls) external;
}

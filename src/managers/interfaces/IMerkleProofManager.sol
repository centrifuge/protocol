// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

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
    bytes4 selector;
    bytes addresses;
    bool valueNonZero;
}

interface IMerkleProofManager {
    event UpdatePolicy(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event ExecuteCall(address indexed target, bytes4 indexed selector, bytes targetData, uint256 value);

    error InsufficientBalance();
    error CallFailed();
    error InvalidProofLength();
    error InvalidTargetDataLength();
    error InvalidValuesLength();
    error InvalidDecodersLength();
    error InvalidProof(PolicyLeaf leaf, bytes32[] proof);
    error NotAStrategist();

    function execute(Call[] calldata calls) external;
}

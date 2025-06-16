// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MerkleProofLib} from "src/misc/libraries/MerkleProofLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {UpdateContractMessageLib, UpdateContractType} from "src/spoke/libraries/UpdateContractMessageLib.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";

import {IMerkleProofManager, Call, PolicyLeaf} from "src/managers/interfaces/IMerkleProofManager.sol";
import {IMerkleProofManagerFactory} from "src/managers/interfaces/IMerkleProofManagerFactory.sol";

/// @title  Merkle Proof Manager
/// @author Inspired by Boring Vaults from Se7en-Seas
contract MerkleProofManager is IMerkleProofManager, IUpdateContract {
    using CastLib for *;

    PoolId public immutable poolId;
    address public immutable spoke;

    mapping(address strategist => bytes32 root) public policy;

    constructor(PoolId poolId_, address spoke_) {
        poolId = poolId_;
        spoke = spoke_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId_, ShareClassId, /* scId */ bytes calldata payload) external {
        require(poolId == poolId_, InvalidPoolId());
        require(msg.sender == spoke, NotAuthorized());

        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));
        if (kind == uint8(UpdateContractType.Policy)) {
            UpdateContractMessageLib.UpdateContractPolicy memory m =
                UpdateContractMessageLib.deserializeUpdateContractPolicy(payload);
            address strategist = m.who.toAddress();

            bytes32 oldRoot = policy[strategist];
            policy[strategist] = m.what;

            emit UpdatePolicy(strategist, oldRoot, m.what);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Strategist actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMerkleProofManager
    function execute(Call[] calldata calls) external {
        bytes32 strategistPolicy = policy[msg.sender];
        require(strategistPolicy != bytes32(0), NotAStrategist());

        for (uint256 i; i < calls.length; ++i) {
            bytes memory addresses = abi.decode(_staticCall(calls[i].decoder, calls[i].targetData), (bytes));
            PolicyLeaf memory leaf = _toPolicyLeaf(calls[i], addresses);

            require(
                MerkleProofLib.verify(calls[i].proof, strategistPolicy, _computeHash(leaf)),
                InvalidProof(leaf, calls[i].proof)
            );

            emit ExecuteCall(calls[i].target, bytes4(calls[i].targetData), calls[i].targetData, calls[i].value);
            _callWithValue(calls[i].target, calls[i].targetData, calls[i].value);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @dev Convert call data + decoded addresses into a merkle tree leaf
    function _toPolicyLeaf(Call memory call, bytes memory addresses) internal pure returns (PolicyLeaf memory) {
        return PolicyLeaf({
            decoder: call.decoder,
            target: call.target,
            selector: bytes4(call.targetData),
            addresses: addresses,
            valueNonZero: call.value > 0
        });
    }

    /// @dev Convert hash of a merkle tree leaf
    function _computeHash(PolicyLeaf memory leaf) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(leaf.decoder, leaf.target, leaf.valueNonZero, leaf.selector, leaf.addresses));
    }

    /// @dev Execute a static call to a contract
    function _staticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returnData) = target.staticcall(data);
        require(success, CallFailed());

        return returnData;
    }

    /// @dev Execute a call with value to a contract
    function _callWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        require(address(this).balance >= value, InsufficientBalance());

        (bool success, bytes memory returnData) = target.call{value: value}(data);
        require(success, WrappedError(target, bytes4(data), returnData, abi.encodeWithSelector(CallFailed.selector)));

        return returnData;
    }
}

contract MerkleProofManagerFactory is IMerkleProofManagerFactory {
    address public immutable spoke;

    constructor(address spoke_) {
        spoke = spoke_;
    }

    /// @inheritdoc IMerkleProofManagerFactory
    function newManager(PoolId poolId) external returns (IMerkleProofManager) {
        MerkleProofManager manager = new MerkleProofManager{salt: bytes32(uint256(poolId.raw()))}(poolId, spoke);

        emit DeployMerkleProofManager(poolId, address(manager));
        return IMerkleProofManager(manager);
    }
}

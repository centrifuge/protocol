// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MerkleProofLib} from "src/misc/libraries/MerkleProofLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";

import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";

import {IMerkleProofManager} from "src/managers/interfaces/IMerkleProofManager.sol";

/// @title  Merkle Proof Manager
/// @author Inspired by Boring Vaults from Se7en-Seas
contract MerkleProofManager is Auth, Recoverable, IMerkleProofManager, IUpdateContract {
    using CastLib for *;

    PoolId public immutable poolId;
    IBalanceSheet public immutable balanceSheet;

    mapping(address strategist => bytes32 root) public policy;

    constructor(PoolId poolId_, IBalanceSheet balanceSheet_, address deployer) Auth(deployer) {
        poolId = poolId_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId, /* poolId */ ShareClassId, /* scId */ bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.Policy)) {
            MessageLib.UpdateContractPolicy memory m = MessageLib.deserializeUpdateContractPolicy(payload);
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
    function execute(
        bytes32[][] calldata proofs,
        address[] calldata decoders,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values
    ) external {
        uint256 numCalls = targets.length;
        require(numCalls == proofs.length, InvalidProofLength());
        require(numCalls == decoders.length, InvalidDecodersLength());
        require(numCalls == targetData.length, InvalidTargetDataLength());
        require(numCalls == values.length, InvalidValuesLength());

        bytes32 strategistPolicy = policy[msg.sender];
        require(strategistPolicy != bytes32(0), NotAStrategist());

        for (uint256 i; i < numCalls; ++i) {
            _verifyCallData(strategistPolicy, proofs[i], decoders[i], targets[i], values[i], targetData[i]);

            _callWithValue(targets[i], targetData[i], values[i]);
            emit ExecuteCall(targets[i], bytes4(targetData[i]), targetData[i], values[i]);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Helper methods
    //----------------------------------------------------------------------------------------------

    function _verifyCallData(
        bytes32 root,
        bytes32[] calldata proof,
        address decoder,
        address target,
        uint256 value,
        bytes calldata targetData
    ) internal view {
        bytes memory addresses = abi.decode(_staticCall(decoder, targetData), (bytes));
        bytes32 leafHash = PolicyLeaf(decoder, target, value > 0, bytes4(targetData), addresses).computeHash();
        require(MerkleProofLib.verify(proof, root, leafHash), InvalidProof(target, targetData, value));
    }

    function _staticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returnData) = target.staticcall(data);
        require(success, CallFailed());

        return returnData;
    }

    function _callWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        require(address(this).balance >= value, InsufficientBalance());

        (bool success, bytes memory returnData) = target.call{value: value}(data);
        require(success, CallFailed());

        return returnData;
    }
}

struct PolicyLeaf {
    address decoder;
    address target;
    bool valueNonZero;
    bytes4 selector;
    bytes addresses;
}

function computeHash(PolicyLeaf memory leaf) pure returns (bytes32) {
    return keccak256(abi.encodePacked(leaf.decoder, leaf.target, leaf.valueNonZero, leaf.selector, leaf.addresses));
}

using {computeHash} for PolicyLeaf global;

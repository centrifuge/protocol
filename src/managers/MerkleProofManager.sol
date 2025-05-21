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

import {IMerkleProofManager, Call, PolicyLeaf} from "src/managers/interfaces/IMerkleProofManager.sol";

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
    function execute(Call[] calldata calls) external {
        bytes32 strategistPolicy = policy[msg.sender];
        require(strategistPolicy != bytes32(0), NotAStrategist());

        for (uint256 i; i < calls.length; ++i) {
            bytes memory addresses = abi.decode(_staticCall(calls[i].decoder, calls[i].targetData), (bytes));
            bytes32 leafHash = computeHash(calls[i].toPolicyLeaf(addresses));
            require(
                MerkleProofLib.verify(calls[i].proof, strategistPolicy, leafHash),
                InvalidProof(calls[i].target, calls[i].targetData, calls[i].value)
            );

            _callWithValue(calls[i].target, calls[i].targetData, calls[i].value);
            emit ExecuteCall(calls[i].target, bytes4(calls[i].targetData), calls[i].targetData, calls[i].value);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Helper methods
    //----------------------------------------------------------------------------------------------

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

function toPolicyLeaf(Call memory call, bytes memory addresses) pure returns (PolicyLeaf memory) {
    return PolicyLeaf({
        decoder: call.decoder,
        target: call.target,
        selector: bytes4(call.targetData),
        addresses: addresses,
        valueNonZero: call.value > 0
    });
}

using {toPolicyLeaf} for Call;

function computeHash(PolicyLeaf memory leaf) pure returns (bytes32) {
    return keccak256(abi.encodePacked(leaf.decoder, leaf.target, leaf.valueNonZero, leaf.selector, leaf.addresses));
}

using {computeHash} for PolicyLeaf;

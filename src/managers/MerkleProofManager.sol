// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {MerkleProofLib} from "src/misc/libraries/MerkleProofLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";

import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";

contract MerkleProofManager is Auth, Recoverable, IUpdateContract {
    using MathLib for uint256;

    event ManageRootUpdated(address indexed strategist, bytes32 oldRoot, bytes32 newRoot);
    event CallsExecuted(uint256 callsMade);

    error InsufficientBalance();
    error CallFailed();
    error InvalidManageProofLength();
    error InvalidTargetDataLength();
    error InvalidValuesLength();
    error InvalidDecodersAndSanitizersLength();
    error FailedToVerifyManageProof(address target, bytes targetData, uint256 value);
    error NotAStrategist();

    IBalanceSheet public immutable balanceSheet;

    mapping(address => bytes32) public manageRoot;
    mapping(PoolId => mapping(address => bool)) public manager;

    constructor(IBalanceSheet balanceSheet_, address deployer) Auth(deployer) {
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId, /* scId */ bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        // TODO: add updateManageRoot
    }

    //----------------------------------------------------------------------------------------------
    // Strategist actions
    //----------------------------------------------------------------------------------------------

    function manageWithMerkleVerification(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values
    ) external {
        uint256 targetsLength = targets.length;
        require(targetsLength == manageProofs.length, InvalidManageProofLength());
        require(targetsLength == targetData.length, InvalidTargetDataLength());
        require(targetsLength == values.length, InvalidValuesLength());
        require(targetsLength == decodersAndSanitizers.length, InvalidDecodersAndSanitizersLength());

        bytes32 strategistManageRoot = manageRoot[msg.sender];
        require(strategistManageRoot != bytes32(0), NotAStrategist());

        for (uint256 i; i < targetsLength; ++i) {
            _verifyCallData(
                strategistManageRoot, manageProofs[i], decodersAndSanitizers[i], targets[i], values[i], targetData[i]
            );
            _functionCallWithValue(targets[i], targetData[i], values[i]);
        }

        emit CallsExecuted(targetsLength);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    // /// @inheritdoc IERC165
    // function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
    //     return interfaceId == type(IERC165).interfaceId;
    // }

    //----------------------------------------------------------------------------------------------
    // Merkle tree verification methods
    //----------------------------------------------------------------------------------------------

    function _verifyCallData(
        bytes32 currentManageRoot,
        bytes32[] calldata manageProof,
        address decoderAndSanitizer,
        address target,
        uint256 value,
        bytes calldata targetData
    ) internal view {
        // Use address decoder to get addresses in call data.
        bytes memory packedArgumentAddresses = abi.decode(_functionStaticCall(decoderAndSanitizer, targetData), (bytes));
        if (
            !_verifyManageProof(
                currentManageRoot,
                manageProof,
                target,
                decoderAndSanitizer,
                value,
                bytes4(targetData),
                packedArgumentAddresses
            )
        ) {
            revert FailedToVerifyManageProof(target, targetData, value);
        }
    }

    function _verifyManageProof(
        bytes32 root,
        bytes32[] calldata proof,
        address target,
        address decoderAndSanitizer,
        uint256 value,
        bytes4 selector,
        bytes memory packedArgumentAddresses
    ) internal pure returns (bool) {
        bool valueNonZero = value > 0;

        bytes32 leaf =
            keccak256(abi.encodePacked(decoderAndSanitizer, target, valueNonZero, selector, packedArgumentAddresses));

        return MerkleProofLib.verify(proof, root, leaf);
    }

    //----------------------------------------------------------------------------------------------
    // Helper methods
    //----------------------------------------------------------------------------------------------

    function _functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returnData) = target.staticcall(data);
        require(success && (returnData.length == 0 || abi.decode(returnData, (bool))), CallFailed());

        return returnData;
    }

    function _functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        require(address(this).balance >= value, InsufficientBalance());

        (bool success, bytes memory returnData) = target.call{value: value}(data);
        require(success && (returnData.length == 0 || abi.decode(returnData, (bool))), CallFailed());

        return returnData;
    }
}

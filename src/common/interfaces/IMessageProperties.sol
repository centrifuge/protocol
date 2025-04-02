// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";

interface IMessageProperties {
    function isMessageRecovery(bytes calldata message) external pure returns (bool);
    function messageLength(bytes calldata message) external pure returns (uint16);
    function messagePoolId(bytes calldata message) external pure returns (PoolId);
    function messageProofHash(bytes calldata message) external pure returns (bytes32);
    function createMessageProof(bytes calldata message) external pure returns (bytes memory);
}

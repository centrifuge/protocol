// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";

import {IMerkleProofManager} from "src/managers/interfaces/IMerkleProofManager.sol";

interface IMerkleProofManagerFactory {
    event DeployMerkleProofManager(PoolId indexed poolId, address indexed manager);

    error InvalidPoolId();

    /// @notice Deploys new merkle proof manager.
    function newManager(PoolId poolId) external returns (IMerkleProofManager);
}

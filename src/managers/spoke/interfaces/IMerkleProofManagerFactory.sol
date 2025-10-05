// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMerkleProofManager} from "./IMerkleProofManager.sol";

import {PoolId} from "../../../core/types/PoolId.sol";

interface IMerkleProofManagerFactory {
    event DeployMerkleProofManager(PoolId indexed poolId, address indexed manager);

    error InvalidPoolId();

    /// @notice Deploys new merkle proof manager.
    function newManager(PoolId poolId) external returns (IMerkleProofManager);
}

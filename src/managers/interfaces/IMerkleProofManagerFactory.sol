// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "centrifuge-v3/src/common/types/PoolId.sol";

import {IMerkleProofManager} from "centrifuge-v3/src/managers/interfaces/IMerkleProofManager.sol";

interface IMerkleProofManagerFactory {
    event DeployMerkleProofManager(PoolId indexed poolId, address indexed manager);

    error InvalidPoolId();

    /// @notice Deploys new merkle proof manager.
    function newManager(PoolId poolId) external returns (IMerkleProofManager);
}

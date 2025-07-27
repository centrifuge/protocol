// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../types/PoolId.sol";
import {IPoolEscrow} from "../../interfaces/IPoolEscrow.sol";

interface IPoolEscrowProvider {
    /// @notice Returns the deterministic address of an escrow contract based on a given pool id wrapped into the
    /// corresponding interface.
    ///
    /// @dev Does not check, whether the escrow was already deployed.
    function escrow(PoolId poolId) external view returns (IPoolEscrow);
}

interface IPoolEscrowFactory is IPoolEscrowProvider {
    event DeployPoolEscrow(PoolId indexed poolId, address indexed escrow);
    event File(bytes32 what, address data);

    error FileUnrecognizedParam();
    error EscrowAlreadyDeployed();

    /// @notice Deploys new escrow and returns it.
    /// @dev All share classes of a pool are represented by the same escrow contract.
    ///
    /// @param poolId Id of the pool this escrow is deployed for
    /// @return IPoolEscrow The the newly deployed escrow contract
    function newEscrow(PoolId poolId) external returns (IPoolEscrow);

    /// @notice Updates contract parameters of type address.
    function file(bytes32 what, address data) external;
}

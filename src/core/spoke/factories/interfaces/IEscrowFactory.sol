// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../types/PoolId.sol";
import {IEscrow} from "../../interfaces/IEscrow.sol";

/// @title  IEscrowProvider
/// @notice Interface for deterministic escrow address resolution
interface IEscrowProvider {
    /// @notice Returns the deterministic address of an escrow contract based on a given pool id
    ///         wrapped into the corresponding interface.
    ///
    /// @dev Does not check, whether the escrow was already deployed.
    function escrow(PoolId poolId) external view returns (IEscrow);

    /// @notice Returns the pool id for a given escrow address.
    ///
    /// @dev Returns the null pool id if the address is not a known escrow deployed by this factory.
    function poolId(address escrow) external view returns (PoolId);
}

/// @title  IEscrowFactory
/// @notice Factory for deploying deterministic escrow contracts
/// @dev    Each pool has a unique escrow contract shared across all its share classes
interface IEscrowFactory is IEscrowProvider {
    event DeployEscrow(PoolId indexed poolId, address indexed escrow);
    event File(bytes32 what, address data);

    error FileUnrecognizedParam();

    /// @notice Root authority that manages ward permissions and timelocked upgrades
    function root() external view returns (address);

    /// @notice Spoke which manages the escrow of each pool
    function spoke() external view returns (address);

    /// @notice Deploys new escrow and returns it.
    /// @dev All share classes of a pool are represented by the same escrow contract.
    ///
    /// @param poolId Id of the pool this escrow is deployed for
    /// @return IEscrow The the newly deployed escrow contract
    function newEscrow(PoolId poolId) external returns (IEscrow);

    /// @notice Updates contract parameters of type address.
    function file(bytes32 what, address data) external;
}

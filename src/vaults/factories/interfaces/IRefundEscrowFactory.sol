// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";

import {IRefundEscrow} from "../../interfaces/IRefundEscrow.sol";

/// @title  IRefundEscrowFactory
/// @notice Factory for deploying refund escrow contracts for vault operations
/// @dev    Each pool has a unique refund escrow for handling failed deposits
interface IRefundEscrowFactory {
    event File(bytes32 what, address data);
    event DeployRefundEscrow(PoolId indexed poolId, address indexed escrow);

    error FileUnrecognizedParam();

    /// @notice Updates contract parameters of type address.
    /// @param what The parameter name to update
    /// @param data The new address value
    function file(bytes32 what, address data) external;

    /// @notice Deploys new escrow and returns it.
    /// @param poolId The pool identifier for which to deploy the escrow
    /// @return The newly deployed refund escrow contract
    function newEscrow(PoolId poolId) external returns (IRefundEscrow);

    /// @notice Returns the escrow
    /// @param poolId The pool identifier
    /// @return The refund escrow contract for the pool
    function get(PoolId poolId) external view returns (IRefundEscrow);
}

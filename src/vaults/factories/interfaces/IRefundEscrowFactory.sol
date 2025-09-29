// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../common/types/PoolId.sol";
import {IRefundEscrow} from "../../interfaces/IRefundEscrow.sol";

interface IRefundEscrowFactory {
    event File(bytes32 what, address data);
    event DeployRefundEscrow(PoolId indexed poolId, address indexed escrow);

    error FileUnrecognizedParam();

    /// @notice Updates contract parameters of type address.
    function file(bytes32 what, address data) external;

    /// @notice Deploys new escrow and returns it.
    function newEscrow(PoolId poolId) external returns (IRefundEscrow);

    /// @notice Returns the escrow
    function get(PoolId poolId) external view returns (IRefundEscrow);
}


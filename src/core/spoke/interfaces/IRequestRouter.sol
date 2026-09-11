// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

/// @notice The spoke-side entry point a request manager calls to forward a request to the Hub. Extracted into
///         its own interface (mirroring the callback side, `IRequestManager.callback`) so a request-manager
///         dispatcher can implement the same `request` shape and sit transparently between sub-managers and the
///         Spoke: a sub-manager targets either the Spoke or the dispatcher through this interface.
interface IRequestRouter {
    /// @notice Handles a request originating from the Spoke side
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param payload The request payload to be processed
    /// @param extraGasLimit Additional gas stipend for cross-chain execution
    /// @param unpaid Whether to allow unpaid mode
    /// @param refund Address to refund excess payment
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable;
}

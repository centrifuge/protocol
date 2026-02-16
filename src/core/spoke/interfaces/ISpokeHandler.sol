// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

/// @notice Interface for SpokeHandler admin/config
interface ISpokeHandler {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event ExecuteTransferShares(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed receiver, uint128 amount
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error OldMetadata();
    error OldHook();
    error InvalidHook();
    error InvalidRequestManager();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts "spokeRegistry", "tokenFactory", "poolEscrowFactory"
    /// @param data The new address
    function file(bytes32 what, address data) external;
}

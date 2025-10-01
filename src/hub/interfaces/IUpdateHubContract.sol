// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

/// @notice Interface for hub-side contracts that can receive updates from spoke
interface IUpdateHubContract {
    error UnknownUpdateHubContractType();

    /// @notice Triggers an update on the hub-side target contract from spoke.
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  sender The spoke-side contract that initiated the update
    /// @param  payload The payload to be processed by the target address
    /// @dev    Target contracts MUST validate the sender address for authorization
    function updateFromSpoke(PoolId poolId, ShareClassId scId, address sender, bytes calldata payload) external;
}

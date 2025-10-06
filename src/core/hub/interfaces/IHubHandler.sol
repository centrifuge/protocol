// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

/// @notice Interface with all methods available in the system used by actors
interface IHubHandler {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event ForwardTransferShares(
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        PoolId indexed poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    );
    event File(bytes32 what, address addr);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    error InvalidRequestManager();

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update (accepts 'hubRegistry', 'holdings', 'sender')
    /// @param data Address of the new contract
    function file(bytes32 what, address data) external;
}

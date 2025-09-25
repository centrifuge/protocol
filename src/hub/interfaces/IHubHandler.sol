// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

/// @notice Interface with all methods available in the system used by actors
interface IHubHandler {
    event ForwardTransferShares(
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        PoolId indexed poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    );

    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    error InvalidRequestManager();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hubRegistry', 'holdings' and 'sender' as string value.
    function file(bytes32 what, address data) external;
}

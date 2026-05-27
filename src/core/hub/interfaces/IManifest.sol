// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

interface IManifest {
    /// @notice Validate whether a Hub call should proceed, and return the timelock duration.
    ///         Revert to block the call. Return 0 for immediate execution.
    /// @dev    Called by the Hub itself from inside {IHub.await}, once per call in the proposed
    ///         batch. Implementations should restrict `msg.sender` to the Hub address.
    /// @param poolId The pool being operated on.
    /// @param caller The address that initiated the await call.
    /// @param data The Hub calldata being proposed.
    /// @return timelock Seconds the operation must wait before execution. 0 = immediate.
    function check(PoolId poolId, address caller, bytes calldata data) external returns (uint48 timelock);
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";

enum TrustedCall {
    AddSentinel,
    RemoveSentinel
}

interface ISupervisor {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event AddSentinel(address indexed sentinel);
    event RemoveSentinel(address indexed sentinel);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotSentinel();
    error AlreadySentinel();
    error ZeroAddress();
    error NotContractUpdater();
    error NotPool();
    error LastSentinel();
    error CannotSelfCancel();

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @notice Cancel a pending authorization (sentinel veto). Callable by any sentinel. A sentinel
    ///         cannot cancel the authorization of their own removal when multiple sentinels exist.
    /// @param data The exact Hub calldata that was authorized.
    function cancelAuthorization(bytes calldata data) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    function hub() external view returns (IHub);
    function poolId() external view returns (PoolId);
    function contractUpdater() external view returns (address);
    function sentinels(address who) external view returns (bool);
    function sentinelCount() external view returns (uint256);
}

interface ISupervisorFactory {
    event DeploySupervisor(PoolId indexed poolId, address indexed supervisor);

    function hub() external view returns (IHub);

    function newSupervisor(PoolId poolId, address contractUpdater) external returns (ISupervisor);

    function previewSupervisor(PoolId poolId, address contractUpdater) external view returns (address);
}

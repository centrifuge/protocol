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
    error NotEnvoy();
    error UnexpectedValue();
    error NotPool();
    error LastSentinel();
    error CannotSelfCancel();

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @notice Cancel a pending Hub authorization (sentinel veto). Callable by any sentinel. A sentinel
    ///         cannot cancel the authorization of their own removal when multiple sentinels exist.
    /// @dev    At a single sentinel that guard is skipped: the set cannot empty itself ({LastSentinel}),
    ///         so replacing a lone sentinel needs an `AddSentinel` first, which that sentinel can veto
    ///         every time it is re-scheduled. Installing a different policy does not break the loop: the
    ///         {IHubRegistry} nonce bump only voids the authorizations already pending, and the veto is
    ///         keyed off the same policy and nonce as the authorization it cancels, so the next
    ///         `AddSentinel` is vetoable again. Recovery is a Root ward doing one of two things.
    ///         {IHub.setPolicy} with the zero policy, since a ward skips enforcement and {IHub} calls into
    ///         a policy only when one is installed, so `AddSentinel` then runs synchronously with no
    ///         authorization to veto. Or {IHubRegistry.updateManager} dropping the Supervisor as a pool
    ///         manager, which makes its {cancelAuthorization} fail the Hub's manager check.
    /// @param data The exact Hub calldata that was authorized.
    function cancelAuthorization(bytes calldata data) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    function hub() external view returns (IHub);
    function poolId() external view returns (PoolId);
    function envoy() external view returns (address);
    function sentinels(address who) external view returns (bool);
    function sentinelCount() external view returns (uint256);
}

interface ISupervisorFactory {
    event DeploySupervisor(PoolId indexed poolId, address indexed supervisor);

    function hub() external view returns (IHub);

    function newSupervisor(PoolId poolId, address envoy) external returns (ISupervisor);

    function previewSupervisor(PoolId poolId, address envoy) external view returns (address);
}

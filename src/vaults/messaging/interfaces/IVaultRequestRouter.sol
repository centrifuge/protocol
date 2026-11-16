// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IVaultRequestManager} from "./IVaultRequestManager.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";
import {ISpokeRequestManager} from "../../../core/spoke/interfaces/ISpokeRequestManager.sol";

/// @notice The per-network singleton registered as every vault pool's spoke request manager. See
///         {VaultRequestRouter}.
interface IVaultRequestRouter is ISpokeRequestManager, IVaultRequestManager, IManagerCallFromHub {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event SetExtraGasLimit(PoolId indexed poolId, uint128 extraGasLimit);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Only the Envoy may set the extra gas limit.
    error NotEnvoy();

    /// @notice The vault is not linked in the spoke registry.
    error NotLinked();

    /// @notice The vault is not the pool's, by the spoke registry or by its own answer.
    error WrongPool();

    /// @notice A callback's share class or asset is not the one its vault was linked for.
    error WrongLane();

    /// @notice Setting the extra gas limit takes no native value.
    error UnexpectedValue();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Extra gas added to every request a pool's vaults send to the hub, for a hub request
    ///         manager heavier than the benchmark. Set through the Envoy (`fromHub`, payload
    ///         `abi.encode(uint128 extraGasLimit)`).
    function extraGasLimit(PoolId poolId) external view returns (uint128);
}

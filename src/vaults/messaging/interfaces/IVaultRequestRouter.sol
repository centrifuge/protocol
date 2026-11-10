// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IVaultRequestManager} from "./IVaultRequestManager.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";
import {ISpokeRequestManager} from "../../../core/spoke/interfaces/ISpokeRequestManager.sol";

/// @notice The per-network singleton registered as every vault pool's spoke request manager. See
///         {VaultRequestRouter}.
interface IVaultRequestRouter is ISpokeRequestManager, IVaultRequestManager, IManagerCallFromHub {
    event SetExtraGasLimit(PoolId indexed poolId, uint128 extraGasLimit);

    error NotEnvoy();
    error NotLinked();
    error WrongPool();
    /// @notice A callback's share class or asset is not the one its vault was linked for.
    error WrongLane();
    error UnexpectedValue();

    /// @notice Extra gas added to every request a pool's vaults send to the hub, for a hub request
    ///         manager heavier than the benchmark. Set through the Envoy (`fromHub`, payload
    ///         `abi.encode(uint128 extraGasLimit)`).
    function extraGasLimit(PoolId poolId) external view returns (uint128);
}

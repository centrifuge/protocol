// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IOnchainPM} from "./IOnchainPM.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {IGateway} from "../../../core/messaging/interfaces/IGateway.sol";

interface IOnchainPMFactory {
    event DeployOnchainPM(PoolId indexed poolId, address indexed onchainPM);

    error InvalidPoolId();

    function envoy() external view returns (address);
    function spoke() external view returns (ISpoke);
    function gateway() external view returns (IGateway);

    /// @notice Deploys a new OnchainPM for the given pool. Reverts if one is already deployed
    ///         (CREATE2 with deterministic salt prevents redeployment).
    function newOnchainPM(PoolId poolId) external returns (IOnchainPM);

    /// @notice Returns the deterministic address for a pool's OnchainPM.
    function getAddress(PoolId poolId) external view returns (address);
}

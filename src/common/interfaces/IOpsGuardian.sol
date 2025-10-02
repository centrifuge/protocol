// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBaseGuardian} from "./IBaseGuardian.sol";
import {ISafe} from "./ISafe.sol";
import {IAdapter} from "./IAdapter.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";

interface IOpsGuardian is IBaseGuardian {
    error AdaptersAlreadyInitialized();
    error AdapterAlreadyWired();

    /// @notice Initialize adapters for a new network (first-time setup only)
    /// @dev Reverts if adapters are already configured for this centrifugeId
    /// @dev Does not trigger cross-chain message - local operation only
    /// @param centrifugeId Target chain ID to configure adapters on
    /// @param adapters Array of adapter contract addresses
    /// @param threshold Minimum number of adapters that must agree
    /// @param recoveryIndex Index of the recovery adapter in the array
    function initAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold, uint8 recoveryIndex)
        external;

    /// @notice Registers a new pool
    function createPool(PoolId poolId, address admin, AssetId currency) external;

    /// @notice Return the linked operational safe
    function opsSafe() external view returns (ISafe);
}

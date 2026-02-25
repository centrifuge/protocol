// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISafe} from "./ISafe.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";

interface IOpsGuardian {
    error NotTheAuthorizedSafe();
    error FileUnrecognizedParam();
    error AdaptersAlreadyInitialized();
    error AdapterAlreadyWired();

    event File(bytes32 indexed what, address data);

    /// @notice Initialize adapters for a new network (first-time setup only)
    /// @dev Reverts if adapters are already configured for this centrifugeId
    /// @dev Does not trigger cross-chain message - local operation only
    /// @param centrifugeId Target chain ID to configure adapters on
    /// @param adapters Array of adapter contract addresses
    /// @param threshold Minimum number of adapters that must agree
    /// @param recoveryIndex Index of the recovery adapter in the array
    function initAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold, uint8 recoveryIndex)
        external;

    /// @notice Wire an adapter to a remote chain (first-time setup only)
    /// @dev Reverts if adapter is already wired for this centrifugeId
    /// @param adapter Address of the adapter to wire
    /// @param centrifugeId The chain ID to wire to
    /// @param data ABI-encoded adapter-specific configuration data
    function wire(address adapter, uint16 centrifugeId, bytes memory data) external;

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'opsSafe', 'hub', or 'multiAdapter'
    /// @param data New value for the parameter
    function file(bytes32 what, address data) external;

    /// @notice Registers a new pool
    /// @param poolId The pool identifier
    /// @param admin The admin address for the pool
    /// @param currency The currency asset ID for the pool
    function createPool(PoolId poolId, address admin, AssetId currency) external;

    /// @notice Return the linked operational safe
    /// @return The operational safe contract
    function opsSafe() external view returns (ISafe);
}

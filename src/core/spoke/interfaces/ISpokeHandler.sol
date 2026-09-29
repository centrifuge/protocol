// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpokeRegistry} from "./ISpokeRegistry.sol";

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IEscrowFactory} from "../factories/interfaces/IEscrowFactory.sol";

/// @notice Interface for SpokeHandler admin/config
interface ISpokeHandler {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event ExecuteTransferShares(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed receiver, uint128 amount
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error InvalidRegistrar();
    error InvalidRequestManager();
    error InvalidSalt();
    error MalformedVaultUpdateMessage();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Stores pool, share class, asset, and price state for the spoke side
    function spokeRegistry() external view returns (ISpokeRegistry);

    /// @notice Deploys pool-specific escrow contracts that custody assets and shares
    function escrowFactory() external view returns (IEscrowFactory);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts "spokeRegistry", "escrowFactory"
    /// @param data The new address
    function file(bytes32 what, address data) external;
}

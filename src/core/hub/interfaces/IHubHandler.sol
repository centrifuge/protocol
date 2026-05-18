// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHub} from "./IHub.sol";
import {IHoldings} from "./IHoldings.sol";
import {IHubRegistry} from "./IHubRegistry.sol";
import {IShareClassManager} from "./IShareClassManager.sol";

import {IHubMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

/// @notice Interface with all methods available in the system used by actors
interface IHubHandler {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event ForwardTransferShares(
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        PoolId indexed poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    );
    event File(bytes32 what, address addr);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    error InvalidRequestManager();

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Name of the parameter to update (accepts 'hubRegistry', 'holdings', 'sender')
    /// @param data Address of the new contract
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Central coordination contract for pool management and cross-chain operations
    function hub() external view returns (IHub);

    /// @notice Tracks asset positions and valuations across all pools and share classes
    function holdings() external view returns (IHoldings);

    /// @notice Registry of pools, assets, and manager permissions on the hub chain
    function hubRegistry() external view returns (IHubRegistry);

    /// @notice Dispatches cross-chain messages from the hub to spoke chains
    function sender() external view returns (IHubMessageSender);

    /// @notice Manages share class creation, pricing, and issuance/revocation tracking
    function shareClassManager() external view returns (IShareClassManager);
}

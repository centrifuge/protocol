// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISafe} from "./ISafe.sol";
import {IAdapter} from "./IAdapter.sol";

interface IAdapterGuardian {
    error NotTheAuthorizedSafe();
    error FileUnrecognizedParam();

    event File(bytes32 indexed what, address data);

    /// @notice Return the linked Safe
    function safe() external view returns (ISafe);

    /// @notice Set adapters cross-chain for global pool
    /// @dev Dispatches SetPoolAdapters message to target chain
    /// @param centrifugeId Target chain ID to configure adapters on
    /// @param adapters Array of adapter contract addresses
    /// @param threshold Minimum number of adapters that must agree
    /// @param recoveryIndex Index of the recovery adapter in the array
    /// @param refund Address to refund excess gas fees
    function setAdapters(
        uint16 centrifugeId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex,
        address refund
    ) external payable;

    /// @notice Locally set a gateway manager for the global pool
    /// @dev Local-only operation for fast emergency response
    /// @param who Address to set as manager
    /// @param canManage True to grant manager rights, false to revoke
    function updateGatewayManager(address who, bool canManage) external;

    /// @notice Block or unblock outgoing messages for global pool 
    /// @dev Local-only operation for fast emergency response
    /// @param centrifugeId Target chain ID to block/unblock
    /// @param isBlocked True to block outgoing messages, false to unblock
    function blockOutgoing(uint16 centrifugeId, bool isBlocked) external;

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'safe', 'sender', 'gateway', or 'multiAdapter' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}

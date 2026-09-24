// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRoot} from "./IRoot.sol";
import {ISafe} from "./ISafe.sol";

import {IScheduleAuthMessageSender} from "../../core/messaging/interfaces/IGatewaySenders.sol";

import {ITokenBridge} from "../../bridge/interfaces/ITokenBridge.sol";

interface IProtocolGuardian {
    error NotTheAuthorizedSafe();
    error FileUnrecognizedParam();
    error NotTheAuthorizedSafeOrItsOwner();

    event File(bytes32 indexed what, address data);

    /// @notice Pause the protocol
    /// @dev callable by both safe and owners
    function pause() external;

    /// @notice Unpause the protocol
    /// @dev callable by safe only
    function unpause() external;

    /// @notice Schedule relying a target address on Root
    /// @dev callable by safe only
    function scheduleRely(address target) external;

    /// @notice Cancel a scheduled rely
    /// @dev callable by safe only
    function cancelRely(address target) external;

    /// @notice Schedule an upgrade (scheduled rely) on a specific chain
    /// @dev    Only supports EVM targets today
    /// @param centrifugeId The chain ID where the upgrade will be scheduled
    /// @param target The address to schedule as a ward
    /// @param refund Address to receive unused gas refund
    function scheduleUpgrade(uint16 centrifugeId, address target, address refund) external payable;

    /// @notice Cancel an upgrade (scheduled rely) on a specific chain
    /// @dev    Only supports EVM targets today
    /// @param centrifugeId The chain ID where the upgrade will be cancelled
    /// @param target The address to cancel the scheduled rely for
    /// @param refund Address to receive unused gas refund
    function cancelUpgrade(uint16 centrifugeId, address target, address refund) external payable;

    /// @notice Configure TokenBridge relayer address
    /// @param relayer The relayer address to set
    function fileTokenBridgeRelayer(address relayer) external;

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'safe', 'sender', or 'tokenBridge'
    /// @param data New value for the parameter
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Root authority that manages ward permissions and timelocked upgrades
    function root() external view returns (IRoot);

    /// @notice Multisig that authorizes protocol-level guardian operations
    function safe() external view returns (ISafe);

    /// @notice Dispatches cross-chain messages for remote upgrade scheduling and cancellation
    function sender() external view returns (IScheduleAuthMessageSender);

    /// @notice TokenBridge used for cross-chain share token transfers
    function tokenBridge() external view returns (ITokenBridge);
}

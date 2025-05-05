// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "src/common/types/PoolId.sol";

/// @notice Defines methods to get properties from raw messages
interface IMessageProperties {
    /// @notice Inspect the message to tell if the message is recovery message
    function isMessageRecovery(bytes calldata message) external pure returns (bool);

    /// @notice Inspect the message to return the length
    function messageLength(bytes calldata message) external pure returns (uint16);

    /// @notice Inspect the message to return the associated PoolId if any
    function messagePoolId(bytes calldata message) external pure returns (PoolId);
}

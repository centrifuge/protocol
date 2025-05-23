// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}

interface IGuardian {
    error NotTheAuthorizedSafe();
    error NotTheAuthorizedSafeOrItsOwner();

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Return the linked Safe
    function safe() external view returns (ISafe);

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'sender' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;

    /// @notice Registers a new pool
    function createPool(PoolId poolId, address admin, AssetId currency) external;

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
    function scheduleUpgrade(uint16 centrifugeId, address target) external;

    /// @notice Cancel an upgrade (scheduled rely) on a specific chain
    /// @dev    Only supports EVM targets today
    function cancelUpgrade(uint16 centrifugeId, address target) external;

    /// @notice Recover tokens on a specific chain
    /// @dev    Only supports EVM targets today
    function recoverTokens(
        uint16 centrifugeId,
        address target,
        address token,
        uint256 tokenId,
        address to,
        uint256 amount
    ) external;

    /// @notice Initiate a gateway payload recovery on a specific chain
    /// @dev    Only supports EVM targets today
    function initiateRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, IAdapter adapter, bytes32 hash)
        external;

    /// @notice Dispute a gateway paylaod recovery on a specific chain
    /// @dev    Only supports EVM targets today
    function disputeRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, IAdapter adapter, bytes32 hash)
        external;
}

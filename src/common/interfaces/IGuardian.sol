// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "./IAdapter.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {IAxelarAdapter} from "../../adapters/interfaces/IAxelarAdapter.sol"; // TODO: extract from guardian
import {IWormholeAdapter} from "../../adapters/interfaces/IWormholeAdapter.sol"; // TODO: extract from guardian

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
    function initiateRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 hash) external;

    /// @notice Dispute a gateway paylaod recovery on a specific chain
    /// @dev    Only supports EVM targets today
    function disputeRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 hash) external;

    /// @notice Wire adapters into MultiAdapter.
    /// @dev Only registers adapters with MultiAdapter and does not configure individual adapters.
    /// @dev For bidirectional communication, perform this setup on the remote MultiAdapter.
    /// @param centrifugeId The destination chain ID to wire adapters for
    /// @param adapters Array of adapter addresses to register with MultiAdapter
    function wireAdapters(uint16 centrifugeId, IAdapter[] calldata adapters) external;

    /// @notice Wire the local Wormhole adapter to a remote one.
    /// @dev For bidirectional communication, perform this setup on the remote adapter.
    /// @param localAdapter The local Wormhole adapter to configure
    /// @param centrifugeId The remote chain's chain ID
    /// @param wormholeId The remote chain's Wormhole ID
    /// @param adapter The remote chain's Wormhole adapter address
    function wireWormholeAdapter(IWormholeAdapter localAdapter, uint16 centrifugeId, uint16 wormholeId, address adapter)
        external;

    /// @notice Wire the local Axelar adapter to a remote one.
    /// @dev For bidirectional communication, perform this setup on the remote adapter.
    /// @param localAdapter The local Axelar adapter to configure
    /// @param centrifugeId The remote chain's chain ID
    /// @param axelarId The remote chain's Axelar ID
    /// @param adapter The remote chain's Axelar adapter address
    function wireAxelarAdapter(
        IAxelarAdapter localAdapter,
        uint16 centrifugeId,
        string calldata axelarId,
        string calldata adapter
    ) external;
}

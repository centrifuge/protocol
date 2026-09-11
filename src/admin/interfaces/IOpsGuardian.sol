// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISafe} from "./ISafe.sol";
import {ICreatePool} from "./ICreatePool.sol";
import {IGasService} from "./IGasService.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../core/messaging/interfaces/IMultiAdapter.sol";

import {ITokenBridge} from "../../bridge/interfaces/ITokenBridge.sol";

interface IOpsGuardian {
    error NotTheAuthorizedSafe();
    error FileUnrecognizedParam();
    error CannotSetAdaptersForLocalChain();
    error CannotSetAdaptersForMainnet();
    error CannotWireLocalChain();
    error CannotWireMainnet();
    error CentrifugeIdAlreadySet();

    event File(bytes32 indexed what, address data);

    /// @notice Set adapters for a remote network (can be called multiple times to update)
    /// @dev Reverts if centrifugeId matches the local chain or the hub chain
    /// @dev Does not trigger cross-chain message - local operation only
    /// @param centrifugeId Target chain ID to configure adapters on
    /// @param adapters Array of adapter contract addresses
    /// @param threshold Minimum number of adapters that must agree
    function setAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold) external;

    /// @notice Wire an adapter to a remote chain (can be called multiple times to re-point a binding)
    /// @dev Reverts if centrifugeId is the local chain or the mainnet (ETHEREUM) hub chain. The ETHEREUM
    ///      connection carries critical messages and can only be wired/rotated through Root, not the
    ///      OpsGuardian; the local chain is never a valid remote wiring target.
    /// @param adapter Address of the adapter to wire
    /// @param centrifugeId The chain ID to wire to
    /// @param data ABI-encoded adapter-specific configuration data
    function wire(address adapter, uint16 centrifugeId, bytes memory data) external;

    /// @notice Mark a global-pool session as blocked, preventing its adapters from voting on messages
    /// @dev Local-only operation for fast emergency response; recovery (unblock) is performed via a Spell
    /// @param centrifugeId Target chain ID
    /// @param sessionId Session to block
    function blockSession(uint16 centrifugeId, uint16 sessionId) external;

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'opsSafe', 'hub', 'tokenBridge', or 'multiAdapter'
    /// @param data New value for the parameter
    function file(bytes32 what, address data) external;

    /// @notice Atomically updates the gas service used by the system
    /// @param gasService the new gas service to use
    function setGasService(IGasService gasService) external;

    /// @notice Registers a new pool
    /// @param poolId The pool identifier
    /// @param admin The admin address for the pool
    /// @param currency The currency asset ID for the pool
    function createPool(PoolId poolId, address admin, AssetId currency) external;

    /// @notice Configure TokenBridge chain ID mapping (first-time only)
    /// @param evmChainId The EVM chain ID
    /// @param centrifugeId The corresponding Centrifuge chain ID
    function fileTokenBridgeCentrifugeId(uint256 evmChainId, uint16 centrifugeId) external;

    /// @notice Return the linked operational safe
    /// @return The operational safe contract
    function opsSafe() external view returns (ISafe);

    /// @notice Hub contract called to register new pools
    function hub() external view returns (ICreatePool);

    /// @notice MultiAdapter used for adapter configuration and wiring on remote networks
    function multiAdapter() external view returns (IMultiAdapter);

    /// @notice TokenBridge used for cross-chain share token transfers
    function tokenBridge() external view returns (ITokenBridge);
}

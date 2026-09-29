// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISafe} from "./ISafe.sol";
import {ICreatePool} from "./ICreatePool.sol";
import {IGasService} from "./IGasService.sol";
import {IAdapterWiring} from "./IAdapterWiring.sol";

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
    error AdaptersAlreadySet();
    error EmptyAdapterSet();
    error CannotWireLocalChain();
    error CentrifugeIdAlreadySet();
    error AdapterAlreadyWired();

    event File(bytes32 indexed what, address data);

    /// @notice Install the global adapter set for a remote network, once
    /// @dev Reverts if centrifugeId matches the local chain or the hub chain
    /// @dev Does not trigger cross-chain message - local operation only
    /// @dev Bootstrap only: reverts once the network has a set, so this installs one and never replaces one.
    ///      Two things ride the global set without requiring a mainnet source: RegisterAsset, and a pool's
    ///      first SetPoolAdapters on a lane, which falls back to global while that pool has no set of its
    ///      own (MessageLib.routePoolId). A safe that could replace a live set could therefore install a
    ///      one-of-one adapter of its own and forge either. Replacing a live set is Root's, over the
    ///      timelock. Containment is not: {blockSession} takes a bad set offline immediately and remains ours
    /// @param centrifugeId Target chain ID to configure adapters on
    /// @param adapters Array of adapter contract addresses
    /// @param threshold Minimum number of adapters that must agree
    function setAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold) external;

    /// @notice Wire an adapter to a remote chain it is not yet wired to
    /// @dev First-time only, per adapter: reverts once `adapter.isWired(centrifugeId, data)` holds, that is when
    ///      the chain already has a destination or the bridge id in `data` already serves another chain, so a
    ///      binding that exists can only be re-pointed or reset by a spell, through Root. A newly deployed
    ///      adapter is unwired for every chain, so the OpsGuardian can still connect it to any chain.
    /// @dev Reverts if centrifugeId is the local chain, which is never a valid remote wiring target.
    /// @param adapter Address of the adapter to wire
    /// @param centrifugeId The chain ID to wire to
    /// @param data ABI-encoded adapter-specific configuration data
    function wire(IAdapterWiring adapter, uint16 centrifugeId, bytes memory data) external;

    /// @notice Mark a global-pool session as blocked, preventing its adapters from voting on messages
    /// @dev Local-only operation for fast emergency response; recovery (unblock) is performed via a Spell
    /// @param centrifugeId Target chain ID
    /// @param sessionId Session to block
    function blockSession(uint16 centrifugeId, uint16 sessionId) external;

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'opsSafe', 'hub', 'tokenBridge', or 'multiAdapter'
    /// @param data New value for the parameter
    function file(bytes32 what, address data) external;

    /// @notice Updates the gas service used by the system, on both contracts that hold a reference to it
    /// @dev    Gas values only. How a message is framed and which source chain it must come from is read from
    ///         the processor and the parser, Root-filed dependencies, so this cannot weaken source-chain
    ///         authentication. Both references move together: leaving MultiAdapter on the old gas service
    ///         would have adapters pricing their receive path against a service Gateway no longer uses.
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "./interfaces/ISafe.sol";
import {ICreatePool} from "./interfaces/ICreatePool.sol";
import {IGasService} from "./interfaces/IGasService.sol";
import {IOpsGuardian} from "./interfaces/IOpsGuardian.sol";
import {IAdapterWiring} from "./interfaces/IAdapterWiring.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {IAdapter} from "../core/messaging/interfaces/IAdapter.sol";
import {IGateway} from "../core/messaging/interfaces/IGateway.sol";
import {IMultiAdapter} from "../core/messaging/interfaces/IMultiAdapter.sol";

import {ITokenBridge} from "../bridge/interfaces/ITokenBridge.sol";

/// @title  OpsGuardian
/// @notice This contract manages operational aspects of the protocol including adapter configuration,
///         network wiring, and pool creation.
contract OpsGuardian is IOpsGuardian {
    PoolId public constant GLOBAL_POOL = PoolId.wrap(0);
    uint16 public constant MAINNET_CENTRIFUGE_ID = 1;

    ISafe public opsSafe;
    ICreatePool public hub;
    ITokenBridge public tokenBridge;
    IMultiAdapter public multiAdapter;

    constructor(ISafe opsSafe_, ICreatePool hub_, ITokenBridge tokenBridge_, IMultiAdapter multiAdapter_) {
        opsSafe = opsSafe_;
        hub = hub_;
        tokenBridge = tokenBridge_;
        multiAdapter = multiAdapter_;
    }

    modifier onlySafe() {
        require(msg.sender == address(opsSafe), NotTheAuthorizedSafe());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "opsSafe") opsSafe = ISafe(data);
        else if (what == "hub") hub = ICreatePool(data);
        else if (what == "tokenBridge") tokenBridge = ITokenBridge(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IOpsGuardian
    function setGasService(IGasService gasService) external onlySafe {
        IGateway(address(multiAdapter.gateway())).file("messageGas", address(gasService));
        multiAdapter.file("messageGas", address(gasService));
    }

    //----------------------------------------------------------------------------------------------
    // Adapter Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function setAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold) external onlySafe {
        // Not redundant with the bootstrap check below. That one still permits a first configuration, and
        // for this one lane even the first is different in kind: ScheduleUpgrade is accepted only from
        // mainnet (MessageLib.messageSourceCentrifugeId) and lands on Root.scheduleRely
        // (MessageProcessor). Whoever installs this lane's first set can forge it. Elsewhere a compromised
        // first set buys a forged RegisterAsset; here it buys Root, so bringing this lane up is a spell.
        require(centrifugeId != MAINNET_CENTRIFUGE_ID, CannotSetAdaptersForMainnet());
        require(centrifugeId != multiAdapter.localCentrifugeId(), CannotSetAdaptersForLocalChain());

        // MultiAdapter permits an empty set (quorum 0, threshold 0). Installing one would still bump the
        // session, and the bootstrap check below would then refuse the correction: the lane would be dead
        // and only Root could revive it. Refuse it here instead.
        require(threshold > 0, EmptyAdapterSet());

        // Bootstrap only. The global set carries RegisterAsset and a pool's first SetPoolAdapters on a
        // lane, so a safe that could replace a live one could forge either; replacing it is Root's, over
        // the timelock. Containment does not wait on that: {blockSession} is immediate and is still ours.
        uint16 targetSessionId = multiAdapter.nextActiveSessionId(centrifugeId, GLOBAL_POOL);
        require(targetSessionId == 1, AdaptersAlreadySet());

        multiAdapter.setAdapters(centrifugeId, GLOBAL_POOL, adapters, threshold, targetSessionId);
    }

    /// @inheritdoc IOpsGuardian
    function wire(IAdapterWiring adapter, uint16 centrifugeId, bytes memory data) external onlySafe {
        require(centrifugeId != multiAdapter.localCentrifugeId(), CannotWireLocalChain());
        require(!adapter.isWired(centrifugeId, data), AdapterAlreadyWired());

        adapter.wire(centrifugeId, data);
    }

    /// @inheritdoc IOpsGuardian
    function blockSession(uint16 centrifugeId, uint16 sessionId) external onlySafe {
        multiAdapter.blockSession(centrifugeId, GLOBAL_POOL, sessionId);
    }

    //----------------------------------------------------------------------------------------------
    // Pool Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function createPool(PoolId poolId, address admin, AssetId currency) external onlySafe {
        hub.createPool(poolId, admin, currency);
    }

    //----------------------------------------------------------------------------------------------
    // Bridge Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function fileTokenBridgeCentrifugeId(uint256 evmChainId, uint16 centrifugeId) external onlySafe {
        require(tokenBridge.chainIdToCentrifugeId(evmChainId) == 0, CentrifugeIdAlreadySet());
        tokenBridge.file("centrifugeId", evmChainId, centrifugeId);
    }
}

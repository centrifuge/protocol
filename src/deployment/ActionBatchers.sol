// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISO4217_DECIMALS, iso4217Codes} from "./Currencies.sol";
import {SetConfigParam, ILayerZeroEndpointV2Like} from "./interfaces/ILayerZeroEndpointV2Like.sol";

import {IAuth} from "../misc/interfaces/IAuth.sol";

import {Hub} from "../core/hub/Hub.sol";
import {Envoy} from "../core/utils/Envoy.sol";
import {Spoke} from "../core/spoke/Spoke.sol";
import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {Holdings} from "../core/hub/Holdings.sol";
import {Accounting} from "../core/hub/Accounting.sol";
import {Gateway} from "../core/messaging/Gateway.sol";
import {HubHandler} from "../core/hub/HubHandler.sol";
import {HubRegistry} from "../core/hub/HubRegistry.sol";
import {SpokeHandler} from "../core/spoke/SpokeHandler.sol";
import {SnapshotQueue} from "../core/spoke/SnapshotQueue.sol";
import {SpokeRegistry} from "../core/spoke/SpokeRegistry.sol";
import {MultiAdapter} from "../core/messaging/MultiAdapter.sol";
import {IAdapter} from "../core/messaging/interfaces/IAdapter.sol";
import {ShareClassManager} from "../core/hub/ShareClassManager.sol";
import {EscrowFactory} from "../core/spoke/factories/EscrowFactory.sol";
import {MessageProcessor} from "../core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../core/messaging/MessageDispatcher.sol";
import {MAX_ADAPTER_COUNT} from "../core/messaging/interfaces/IMultiAdapter.sol";

import {Root} from "../admin/Root.sol";
import {GasService} from "../admin/GasService.sol";
import {ISafe} from "../admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../admin/ProtocolGuardian.sol";
import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

import {FreezeOnly} from "../token/hooks/FreezeOnly.sol";
import {NAVManager} from "../hooks/accounting/NAVManager.sol";
import {FullRestrictions} from "../token/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../token/hooks/FreelyTransferable.sol";
import {BridgeCircuitBreaker} from "../hooks/bridge/BridgeCircuitBreaker.sol";
import {SimplePriceManager} from "../hooks/accounting/SimplePriceManager.sol";
import {RedemptionRestrictions} from "../token/hooks/RedemptionRestrictions.sol";

import {QueueManager} from "../managers/spoke/QueueManager.sol";
import {ShareManager} from "../managers/spoke/ShareManager.sol";
import {OnOffRampFactory} from "../managers/spoke/OnOffRamp.sol";

import {OracleValuation} from "../valuations/OracleValuation.sol";
import {IdentityValuation} from "../valuations/IdentityValuation.sol";

import {SyncManager} from "../vaults/SyncManager.sol";
import {VaultRouter} from "../vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../vaults/factories/SyncDepositVaultFactory.sol";

import {TokenBridge} from "../bridge/TokenBridge.sol";
import {SubsidyManager} from "../utils/SubsidyManager.sol";
import {AxelarAdapter} from "../adapters/AxelarAdapter.sol";
import {StandbyAdapter} from "../adapters/StandbyAdapter.sol";
import {ChainlinkAdapter} from "../adapters/ChainlinkAdapter.sol";
import {HyperlaneAdapter} from "../adapters/HyperlaneAdapter.sol";
import {LayerZeroAdapter} from "../adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../utils/RefundEscrowFactory.sol";
import {ShareTokenRegistrar} from "../token/ShareTokenRegistrar.sol";
import {IInterchainSecurityModule} from "../adapters/interfaces/IHyperlaneAdapter.sol";

struct CoreReport {
    Gateway gateway;
    MultiAdapter multiAdapter;
    MessageProcessor messageProcessor;
    MessageDispatcher messageDispatcher;
    EscrowFactory escrowFactory;
    Spoke spoke;
    SnapshotQueue snapshotQueue;
    ShareTokenRegistrar shareTokenRegistrar;
    SpokeHandler spokeHandler;
    SpokeRegistry spokeRegistry;
    Envoy envoy;
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    HubHandler hubHandler;
    Hub hub;
    Root root;
    ProtocolGuardian protocolGuardian;
    OpsGuardian opsGuardian;
    GasService gasService;
}

struct NonCoreReport {
    CoreReport core;
    SubsidyManager subsidyManager;
    RefundEscrowFactory refundEscrowFactory;
    AsyncVaultFactory asyncVaultFactory;
    AsyncRequestManager asyncRequestManager;
    SyncDepositVaultFactory syncDepositVaultFactory;
    SyncManager syncManager;
    VaultRouter vaultRouter;
    FreezeOnly freezeOnlyHook;
    FullRestrictions fullRestrictionsHook;
    FreelyTransferable freelyTransferableHook;
    RedemptionRestrictions redemptionRestrictionsHook;
    QueueManager queueManager;
    OnOffRampFactory onOffRampFactory;
    ShareManager shareManager;
    BatchRequestManager batchRequestManager;
    IdentityValuation identityValuation;
    OracleValuation oracleValuation;
    NAVManager navManager;
    SimplePriceManager simplePriceManager;
    TokenBridge tokenBridge;
    BridgeCircuitBreaker bridgeCircuitBreaker;
}

struct AdaptersReport {
    CoreReport core;
    LayerZeroAdapter layerZeroAdapter;
    AxelarAdapter axelarAdapter;
    ChainlinkAdapter chainlinkAdapter;
    HyperlaneAdapter hyperlaneAdapter;
    StandbyAdapter layerZeroStandby;
    StandbyAdapter axelarStandby;
    StandbyAdapter chainlinkStandby;
    StandbyAdapter hyperlaneStandby;
}

/// @dev    An adapter whose id is set is wired to the lane. It also joins the lane's global adapter set unless
///         flagged `*WiredOnly`, in which case it stays out of it: bound to its peer and ready for a pool to
///         include in its own set, but carrying none of the global pool's messages. `threshold` counts the
///         global set only.
struct AdapterConnections {
    uint16 centrifugeId;
    uint32 layerZeroId;
    string axelarId;
    uint64 chainlinkId;
    uint32 hyperlaneId;
    uint8 threshold;
    bool layerZeroWiredOnly;
    bool axelarWiredOnly;
    bool chainlinkWiredOnly;
    bool hyperlaneWiredOnly;
}

/// @notice Thrown when a batcher is told to wire Root but is not a ward of it, or the other way round: the
///         deployment and the Root on the chain disagree about whether that Root was deployed by this run.
error RootAccessMismatch();

contract CoreActionBatcher {
    constructor(
        CoreReport memory report,
        ISafe protocolSafe,
        ISafe opsSafe,
        address adapterBatcher_,
        address nonCoreBatcher_,
        bool wireRoot
    ) {
        address root = address(report.root);

        // False where the chain already carried its Root, which leaves everything reaching into it to
        // `RootFixes`. Passed in rather than inferred, and checked against the ward that has to follow from
        // it, so the two can never drift: wiring Root without the ward reverts, and skipping it while holding
        // the ward would leave this contract a ward of Root for good
        require(wireRoot == (report.root.wards(address(this)) == 1), RootAccessMismatch());

        // Rely root
        report.gateway.rely(root);
        report.multiAdapter.rely(root);

        report.messageDispatcher.rely(root);
        report.messageProcessor.rely(root);

        report.escrowFactory.rely(root);
        report.shareTokenRegistrar.rely(root);
        report.spoke.rely(root);
        report.snapshotQueue.rely(root);
        report.spokeRegistry.rely(root);
        report.spokeHandler.rely(root);
        report.envoy.rely(root);

        report.hubRegistry.rely(root);
        report.accounting.rely(root);
        report.holdings.rely(root);
        report.shareClassManager.rely(root);
        report.hub.rely(root);
        report.hubHandler.rely(root);

        // Rely gateway
        report.multiAdapter.rely(address(report.gateway));
        report.messageProcessor.rely(address(report.gateway));

        // Rely multiAdapter
        report.gateway.rely(address(report.multiAdapter));

        // Rely messageDispatcher
        report.gateway.rely(address(report.messageDispatcher));
        report.multiAdapter.rely(address(report.messageDispatcher));
        report.envoy.rely(address(report.messageDispatcher));
        report.hubHandler.rely(address(report.messageDispatcher));
        if (wireRoot) report.root.rely(address(report.messageDispatcher));

        // Rely messageProcessor
        report.gateway.rely(address(report.messageProcessor));
        report.multiAdapter.rely(address(report.messageProcessor));
        report.hubHandler.rely(address(report.messageProcessor));
        report.envoy.rely(address(report.messageProcessor));
        if (wireRoot) report.root.rely(address(report.messageProcessor));

        // Rely spoke
        report.messageDispatcher.rely(address(report.spoke));
        report.snapshotQueue.rely(address(report.spoke));

        // Rely spokeHandler
        report.spokeHandler.rely(address(report.messageProcessor));
        report.spokeHandler.rely(address(report.messageDispatcher));
        report.escrowFactory.rely(address(report.spokeHandler));

        // Rely shareTokenRegistrar: core contracts operate share tokens exclusively through the registrar
        report.shareTokenRegistrar.rely(address(report.spokeHandler));
        report.shareTokenRegistrar.rely(address(report.spoke));

        // Rely spokeRegistry
        report.spokeRegistry.rely(address(report.spokeHandler));
        report.spokeRegistry.rely(address(report.spoke));

        // Rely hub
        report.multiAdapter.rely(address(report.hub));
        report.accounting.rely(address(report.hub));
        report.holdings.rely(address(report.hub));
        report.hubRegistry.rely(address(report.hub));
        report.shareClassManager.rely(address(report.hub));
        report.messageDispatcher.rely(address(report.hub));

        // Rely hubHandler
        report.hubRegistry.rely(address(report.hubHandler));
        report.holdings.rely(address(report.hubHandler));
        report.shareClassManager.rely(address(report.hubHandler));
        report.hub.rely(address(report.hubHandler));
        report.messageDispatcher.rely(address(report.hubHandler));

        // Rely protocolGuardian
        report.messageDispatcher.rely(address(report.protocolGuardian));
        if (wireRoot) report.root.rely(address(report.protocolGuardian));

        // Rely opsGuardian
        report.multiAdapter.rely(address(report.opsGuardian));
        report.gateway.rely(address(report.opsGuardian));
        report.hub.rely(address(report.opsGuardian));

        // File methods
        report.gateway.file("adapter", address(report.multiAdapter));
        report.gateway.file("messageGas", address(report.gasService));
        report.gateway.file("processor", address(report.messageProcessor));

        report.multiAdapter.file("parser", address(report.messageProcessor));
        report.multiAdapter.file("messageGas", address(report.gasService));

        report.messageDispatcher.file("spokeHandler", address(report.spokeHandler));
        report.messageDispatcher.file("multiAdapter", address(report.multiAdapter));
        report.messageDispatcher.file("envoy", address(report.envoy));
        report.messageDispatcher.file("hubHandler", address(report.hubHandler));

        report.messageProcessor.file("multiAdapter", address(report.multiAdapter));
        report.messageProcessor.file("gateway", address(report.gateway));
        report.messageProcessor.file("spokeHandler", address(report.spokeHandler));
        report.messageProcessor.file("envoy", address(report.envoy));
        report.messageProcessor.file("hubHandler", address(report.hubHandler));

        report.escrowFactory.file("spoke", address(report.spoke));

        // Hook/vault/ward updates arrive via Hub.managerCall -> Envoy -> registrar.fromHub, resolving the token
        report.shareTokenRegistrar.file("envoy", address(report.envoy));
        report.shareTokenRegistrar.file("spokeRegistry", address(report.spokeRegistry));

        // A kept Root means a previous release whose assets the launch spell replays under their old ids, so the
        // permissionless `registerAsset` has nowhere to send until the spell has done so and filed the dispatcher
        if (wireRoot) report.spoke.file("sender", address(report.messageDispatcher));

        report.hub.file("sender", address(report.messageDispatcher));

        report.hubHandler.file("sender", address(report.messageDispatcher));

        report.opsGuardian.file("opsSafe", address(opsSafe));
        report.protocolGuardian.file("safe", address(protocolSafe));

        // Endorse methods
        if (wireRoot) report.root.endorse(address(report.spoke));

        // Initial configuration
        AssetId[] memory currencies = iso4217Codes();
        for (uint256 i; i < currencies.length; i++) {
            report.hubRegistry.registerAsset(currencies[i], ISO4217_DECIMALS);
        }

        // Other batchers
        report.multiAdapter.rely(adapterBatcher_);
        if (wireRoot) report.root.rely(nonCoreBatcher_);

        // Revoke batcher permissions
        report.gateway.deny(address(this));
        report.multiAdapter.deny(address(this));

        report.messageProcessor.deny(address(this));
        report.messageDispatcher.deny(address(this));

        report.spoke.deny(address(this));
        report.snapshotQueue.deny(address(this));
        report.shareTokenRegistrar.deny(address(this));
        report.escrowFactory.deny(address(this));
        report.spokeRegistry.deny(address(this));
        report.spokeHandler.deny(address(this));
        report.envoy.deny(address(this));

        report.hubRegistry.deny(address(this));
        report.accounting.deny(address(this));
        report.holdings.deny(address(this));
        report.shareClassManager.deny(address(this));
        report.hub.deny(address(this));
        report.hubHandler.deny(address(this));

        if (wireRoot) report.root.deny(address(this));
    }
}

contract NonCoreActionBatcher {
    constructor(NonCoreReport memory report, bool wireRoot) {
        address root = address(report.core.root);

        // As in `CoreActionBatcher`. The ward this checks is the one that batcher granted, under the same flag
        require(wireRoot == (report.core.root.wards(address(this)) == 1), RootAccessMismatch());

        // Rely Root
        report.tokenBridge.rely(root);
        report.tokenBridge.rely(address(report.core.protocolGuardian));
        report.tokenBridge.rely(address(report.core.opsGuardian));
        report.subsidyManager.rely(root);
        report.refundEscrowFactory.rely(root);
        report.asyncVaultFactory.rely(root);
        report.asyncRequestManager.rely(root);
        report.syncDepositVaultFactory.rely(root);
        report.syncManager.rely(root);
        report.vaultRouter.rely(root);

        report.freezeOnlyHook.rely(root);
        report.fullRestrictionsHook.rely(root);
        report.freelyTransferableHook.rely(root);
        report.redemptionRestrictionsHook.rely(root);

        report.batchRequestManager.rely(root);

        // Rely bridgeCircuitBreaker
        report.bridgeCircuitBreaker.rely(root);
        report.bridgeCircuitBreaker.rely(address(report.core.hubHandler));

        // Rely spokeHandler
        report.asyncRequestManager.rely(address(report.core.spokeHandler));
        report.freezeOnlyHook.rely(address(report.core.shareTokenRegistrar));
        report.fullRestrictionsHook.rely(address(report.core.shareTokenRegistrar));
        report.freelyTransferableHook.rely(address(report.core.shareTokenRegistrar));
        report.redemptionRestrictionsHook.rely(address(report.core.shareTokenRegistrar));
        report.asyncVaultFactory.rely(address(report.core.spokeHandler));
        report.syncDepositVaultFactory.rely(address(report.core.spokeHandler));

        // Rely hubHandler
        report.batchRequestManager.rely(address(report.core.hubHandler));

        // Rely subsidyManager
        report.refundEscrowFactory.rely(address(report.subsidyManager));

        // Rely asyncRequestManager
        report.subsidyManager.rely(address(report.asyncRequestManager));

        // Rely asyncVaultFactory
        report.asyncRequestManager.rely(address(report.asyncVaultFactory));

        // Rely syncDepositVaultFactory
        report.syncManager.rely(address(report.syncDepositVaultFactory));
        report.asyncRequestManager.rely(address(report.syncDepositVaultFactory));

        // File methods
        report.refundEscrowFactory.file(bytes32("controller"), address(report.subsidyManager));
        report.refundEscrowFactory.file(bytes32("root"), root);

        report.asyncRequestManager.file("spoke", address(report.core.spoke));
        report.asyncRequestManager.file("spokeRegistry", address(report.core.spokeRegistry));

        report.syncManager.file("spoke", address(report.core.spoke));
        report.syncManager.file("spokeRegistry", address(report.core.spokeRegistry));
        report.syncManager.file("envoy", address(report.core.envoy));

        report.subsidyManager.file("envoy", address(report.core.envoy));

        report.batchRequestManager.file("hub", address(report.core.hub));

        // Endorse methods
        if (wireRoot) {
            report.core.root.endorse(address(report.asyncRequestManager));
            report.core.root.endorse(address(report.vaultRouter));
            report.core.root.endorse(address(report.tokenBridge));
            // The ShareManager needs it to pull shares on the revoke path, and it is safe to grant: its only
            // entrypoint is the envoy-gated `fromHub`, so every call matured through the hub policy, and it
            // holds nothing between calls. What it cannot do is give the endorsement back for a stray token:
            // `fromHub` carries only a `poolId`, so the contract has no way to tell which pool an arbitrary
            // token belongs to, and anything sent here needs administrative recovery instead
            report.core.root.endorse(address(report.shareManager));
        }

        // Revoke batcher permissions
        report.tokenBridge.deny(address(this));
        report.refundEscrowFactory.deny(address(this));
        report.asyncVaultFactory.deny(address(this));
        report.asyncRequestManager.deny(address(this));
        report.syncDepositVaultFactory.deny(address(this));
        report.syncManager.deny(address(this));
        report.vaultRouter.deny(address(this));
        report.subsidyManager.deny(address(this));

        report.freezeOnlyHook.deny(address(this));
        report.fullRestrictionsHook.deny(address(this));
        report.freelyTransferableHook.deny(address(this));
        report.redemptionRestrictionsHook.deny(address(this));

        report.batchRequestManager.deny(address(this));

        report.bridgeCircuitBreaker.deny(address(this));

        if (wireRoot) report.core.root.deny(address(this));
    }
}

contract AdapterActionBatcher {
    constructor(
        AdaptersReport memory report,
        ISafe protocolSafe,
        AdapterConnections[] memory connectionList,
        SetConfigParam[] memory layerZeroConfigParams,
        address layerZeroDelegate,
        string memory remoteAxelarAdapter,
        string memory remoteAxelarStandby,
        address hyperlaneIsm
    ) {
        _relyAdapters(report, address(report.core.root));
        _relyAdapters(report, address(report.core.opsGuardian));

        // Rely protocolSafe on LayerZero (needed for setDelegate calls)
        if (address(report.layerZeroAdapter) != address(0)) {
            report.layerZeroAdapter.rely(address(protocolSafe));
        }

        // Rely protocolSafe on Hyperlane (needed for post-deploy setIsm calls)
        if (address(report.hyperlaneAdapter) != address(0)) {
            report.hyperlaneAdapter.rely(address(protocolSafe));
        }

        // Standbys join no set, but their underlyings take the same wards and the same bridge configuration as the
        // global adapters, and are wired to the same lanes, so a pool can take one up as it is and it verifies as
        // the protocol does
        _relyStandbys(report, protocolSafe);

        // Connect adapters
        for (uint256 i; i < connectionList.length; i++) {
            AdapterConnections memory connections = connectionList[i];

            uint256 n;
            IAdapter[] memory adapters = new IAdapter[](MAX_ADAPTER_COUNT);

            if (address(report.layerZeroAdapter) != address(0) && connections.layerZeroId != 0) {
                report.layerZeroAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.layerZeroId, report.layerZeroAdapter));
                if (!connections.layerZeroWiredOnly) adapters[n++] = report.layerZeroAdapter;

                if (layerZeroConfigParams.length > 0) {
                    _setLayerZeroUlnConfig(report.layerZeroAdapter, connections.layerZeroId, layerZeroConfigParams[i]);
                    _setStandbyUlnConfig(report.layerZeroStandby, connections.layerZeroId, layerZeroConfigParams[i]);
                }
            }

            if (address(report.axelarAdapter) != address(0) && bytes(connections.axelarId).length != 0) {
                report.axelarAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.axelarId, remoteAxelarAdapter));
                if (!connections.axelarWiredOnly) adapters[n++] = report.axelarAdapter;
            }

            if (address(report.chainlinkAdapter) != address(0) && connections.chainlinkId != 0) {
                report.chainlinkAdapter
                    .wire(
                        connections.centrifugeId,
                        // Full finality both ways; a lane is migrated to faster-than-finality by governance, not at launch
                        abi.encode(connections.chainlinkId, report.chainlinkAdapter, bytes4(0), bytes4(0))
                    );

                if (!connections.chainlinkWiredOnly) adapters[n++] = report.chainlinkAdapter;
            }

            if (address(report.hyperlaneAdapter) != address(0) && connections.hyperlaneId != 0) {
                report.hyperlaneAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.hyperlaneId, report.hyperlaneAdapter));
                if (!connections.hyperlaneWiredOnly) adapters[n++] = report.hyperlaneAdapter;
            }

            _wireStandbys(report, connections, remoteAxelarStandby);

            if (n > 0) {
                assembly {
                    mstore(adapters, n)
                }
                report.core.multiAdapter
                    .setAdapters(
                        connections.centrifugeId,
                        PoolId.wrap(0),
                        adapters,
                        connections.threshold > 0 ? connections.threshold : uint8(adapters.length),
                        1 // fresh-deploy bootstrap of the global pool: the next session id is always 1
                    );
            }
        }

        if (address(report.layerZeroAdapter) != address(0)) {
            // Set delegate to the right address after setting the ULN config
            report.layerZeroAdapter.setDelegate(layerZeroDelegate);
        }

        // Set the ISM so inbound verification does not fall back to the Mailbox default ISM
        if (address(report.hyperlaneAdapter) != address(0) && hyperlaneIsm != address(0)) {
            report.hyperlaneAdapter.setIsm(IInterchainSecurityModule(hyperlaneIsm));
        }

        _finalizeStandbys(report, layerZeroDelegate, hyperlaneIsm);

        // Revoke batcher permissions
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.deny(address(this));
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.deny(address(this));
        if (address(report.chainlinkAdapter) != address(0)) report.chainlinkAdapter.deny(address(this));
        if (address(report.hyperlaneAdapter) != address(0)) report.hyperlaneAdapter.deny(address(this));

        _denyStandby(_underlying(report.layerZeroStandby));
        _denyStandby(_underlying(report.axelarStandby));
        _denyStandby(_underlying(report.chainlinkStandby));
        _denyStandby(_underlying(report.hyperlaneStandby));

        report.core.multiAdapter.deny(address(this));
    }

    function _relyAdapters(AdaptersReport memory report, address ward) internal {
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.rely(ward);
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.rely(ward);
        if (address(report.chainlinkAdapter) != address(0)) report.chainlinkAdapter.rely(ward);
        if (address(report.hyperlaneAdapter) != address(0)) report.hyperlaneAdapter.rely(ward);
    }

    /// @dev The standby itself holds no wards: what is administered is the bridge adapter under it
    function _underlying(StandbyAdapter standby) internal view returns (address) {
        return address(standby) != address(0) ? address(standby.underlying()) : address(0);
    }

    /// @dev Each underlying takes the wards its global adapter has. Written out per contract rather than
    ///      through a loop, so that `check_ward_coverage.py` reads every grant and pairs it with its assertion
    function _relyStandbys(AdaptersReport memory report, ISafe protocolSafe) internal {
        if (address(report.layerZeroStandby) != address(0)) {
            IAuth layerZeroStandbyUnderlying = IAuth(address(report.layerZeroStandby.underlying()));
            layerZeroStandbyUnderlying.rely(address(report.core.root));
            layerZeroStandbyUnderlying.rely(address(report.core.opsGuardian));
            // Needed for setDelegate calls
            layerZeroStandbyUnderlying.rely(address(protocolSafe));
        }

        if (address(report.axelarStandby) != address(0)) {
            IAuth axelarStandbyUnderlying = IAuth(address(report.axelarStandby.underlying()));
            axelarStandbyUnderlying.rely(address(report.core.root));
            axelarStandbyUnderlying.rely(address(report.core.opsGuardian));
        }

        if (address(report.chainlinkStandby) != address(0)) {
            IAuth chainlinkStandbyUnderlying = IAuth(address(report.chainlinkStandby.underlying()));
            chainlinkStandbyUnderlying.rely(address(report.core.root));
            chainlinkStandbyUnderlying.rely(address(report.core.opsGuardian));
        }

        if (address(report.hyperlaneStandby) != address(0)) {
            IAuth hyperlaneStandbyUnderlying = IAuth(address(report.hyperlaneStandby.underlying()));
            hyperlaneStandbyUnderlying.rely(address(report.core.root));
            hyperlaneStandbyUnderlying.rely(address(report.core.opsGuardian));
            // Needed for post-deploy setIsm calls
            hyperlaneStandbyUnderlying.rely(address(protocolSafe));
        }
    }

    /// @dev The peer is the remote standby underlying, never the remote global adapter, so a forwarded vote lands
    ///      on the standby at the other end. As with the global adapters, it is taken to sit at this chain's address
    function _wireStandbys(
        AdaptersReport memory report,
        AdapterConnections memory connections,
        string memory remoteAxelarStandby
    ) internal {
        address layerZero = _underlying(report.layerZeroStandby);
        if (layerZero != address(0) && connections.layerZeroId != 0) {
            IAdapterWiring(layerZero).wire(connections.centrifugeId, abi.encode(connections.layerZeroId, layerZero));
        }

        address axelar = _underlying(report.axelarStandby);
        if (axelar != address(0) && bytes(connections.axelarId).length != 0) {
            IAdapterWiring(axelar).wire(connections.centrifugeId, abi.encode(connections.axelarId, remoteAxelarStandby));
        }

        address chainlink = _underlying(report.chainlinkStandby);
        if (chainlink != address(0) && connections.chainlinkId != 0) {
            IAdapterWiring(chainlink)
                .wire(connections.centrifugeId, abi.encode(connections.chainlinkId, chainlink, bytes4(0), bytes4(0)));
        }

        address hyperlane = _underlying(report.hyperlaneStandby);
        if (hyperlane != address(0) && connections.hyperlaneId != 0) {
            IAdapterWiring(hyperlane).wire(connections.centrifugeId, abi.encode(connections.hyperlaneId, hyperlane));
        }
    }

    /// @dev Configured like the global adapter: otherwise a pool taking it up would verify with LayerZero's
    ///      default libraries and DVNs rather than the protocol's
    function _setStandbyUlnConfig(StandbyAdapter standby, uint32 eid, SetConfigParam memory param) internal {
        address underlying = _underlying(standby);
        if (underlying != address(0)) _setLayerZeroUlnConfig(LayerZeroAdapter(underlying), eid, param);
    }

    /// @dev The same hand-over the global adapters get: the delegate once the ULN config is set, and the ISM
    ///      so inbound verification does not fall back to the Mailbox default
    function _finalizeStandbys(AdaptersReport memory report, address layerZeroDelegate, address hyperlaneIsm) internal {
        address layerZero = _underlying(report.layerZeroStandby);
        if (layerZero != address(0)) LayerZeroAdapter(layerZero).setDelegate(layerZeroDelegate);

        address hyperlane = _underlying(report.hyperlaneStandby);
        if (hyperlane != address(0) && hyperlaneIsm != address(0)) {
            HyperlaneAdapter(hyperlane).setIsm(IInterchainSecurityModule(hyperlaneIsm));
        }
    }

    function _denyStandby(address underlying) internal {
        if (underlying != address(0)) IAuth(underlying).deny(address(this));
    }

    function _setLayerZeroUlnConfig(LayerZeroAdapter adapter, uint32 eid, SetConfigParam memory param) internal {
        ILayerZeroEndpointV2Like endpoint = ILayerZeroEndpointV2Like(address(adapter.endpoint()));
        address oapp = address(adapter);
        address sendLib = endpoint.defaultSendLibrary(eid);
        address recvLib = endpoint.defaultReceiveLibrary(eid);

        // Set send and receive libraries
        // Because we set the config on these libraries, we need to set them explicitly
        // Even though they are the default ones, as the defaults may change
        endpoint.setSendLibrary(oapp, eid, sendLib);
        endpoint.setReceiveLibrary(oapp, eid, recvLib, 0);

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = param;

        endpoint.setConfig(oapp, sendLib, params);
        endpoint.setConfig(oapp, recvLib, params);
    }
}

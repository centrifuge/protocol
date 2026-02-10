// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Hub} from "../core/hub/Hub.sol";
import {Spoke} from "../core/spoke/Spoke.sol";
import {PoolId} from "../core/types/PoolId.sol";
import {Holdings} from "../core/hub/Holdings.sol";
import {Accounting} from "../core/hub/Accounting.sol";
import {Gateway} from "../core/messaging/Gateway.sol";
import {HubHandler} from "../core/hub/HubHandler.sol";
import {HubRegistry} from "../core/hub/HubRegistry.sol";
import {BalanceSheet} from "../core/spoke/BalanceSheet.sol";
import {GasService} from "../core/messaging/GasService.sol";
import {AssetId, newAssetId} from "../core/types/AssetId.sol";
import {VaultRegistry} from "../core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../core/utils/ContractUpdater.sol";
import {IAdapter} from "../core/messaging/interfaces/IAdapter.sol";
import {ShareClassManager} from "../core/hub/ShareClassManager.sol";
import {TokenFactory} from "../core/spoke/factories/TokenFactory.sol";
import {MessageProcessor} from "../core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../core/spoke/factories/PoolEscrowFactory.sol";
import {MAX_ADAPTER_COUNT} from "../core/messaging/interfaces/IMultiAdapter.sol";

import {Root} from "../admin/Root.sol";
import {ISafe} from "../admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../admin/OpsGuardian.sol";
import {TokenRecoverer} from "../admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../hooks/FreezeOnly.sol";
import {FullRestrictions} from "../hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../hooks/RedemptionRestrictions.sol";

import {NAVManager} from "../managers/hub/NAVManager.sol";
import {QueueManager} from "../managers/spoke/QueueManager.sol";
import {VaultDecoder} from "../managers/spoke/decoders/VaultDecoder.sol";
import {SimplePriceManager} from "../managers/hub/SimplePriceManager.sol";
import {CircleDecoder} from "../managers/spoke/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../managers/spoke/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../managers/spoke/MerkleProofManager.sol";

import {OracleValuation} from "../valuations/OracleValuation.sol";
import {IdentityValuation} from "../valuations/IdentityValuation.sol";

import {SyncManager} from "../vaults/SyncManager.sol";
import {VaultRouter} from "../vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../vaults/factories/SyncDepositVaultFactory.sol";

import {SetConfigParam, ILayerZeroEndpointV2Like} from "./interfaces/ILayerZeroEndpointV2Like.sol";

import {SubsidyManager} from "../utils/SubsidyManager.sol";
import {AxelarAdapter} from "../adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../utils/RefundEscrowFactory.sol";

struct CoreReport {
    Gateway gateway;
    MultiAdapter multiAdapter;
    GasService gasService;
    MessageProcessor messageProcessor;
    MessageDispatcher messageDispatcher;
    PoolEscrowFactory poolEscrowFactory;
    Spoke spoke;
    BalanceSheet balanceSheet;
    TokenFactory tokenFactory;
    ContractUpdater contractUpdater;
    VaultRegistry vaultRegistry;
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    HubHandler hubHandler;
    Hub hub;
    Root root;
    TokenRecoverer tokenRecoverer;
    ProtocolGuardian protocolGuardian;
    OpsGuardian opsGuardian;
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
    OnOfframpManagerFactory onOfframpManagerFactory;
    MerkleProofManagerFactory merkleProofManagerFactory;
    VaultDecoder vaultDecoder;
    CircleDecoder circleDecoder;
    BatchRequestManager batchRequestManager;
    IdentityValuation identityValuation;
    OracleValuation oracleValuation;
    NAVManager navManager;
    SimplePriceManager simplePriceManager;
}

struct AdaptersReport {
    CoreReport core;
    LayerZeroAdapter layerZeroAdapter;
    WormholeAdapter wormholeAdapter;
    AxelarAdapter axelarAdapter;
    ChainlinkAdapter chainlinkAdapter;
}

struct AdapterConnections {
    uint16 centrifugeId;
    uint32 layerZeroId;
    uint16 wormholeId;
    string axelarId;
    uint64 chainlinkId;
    uint8 threshold;
}

abstract contract Constants {
    uint8 public constant ISO4217_DECIMALS = 18;
    AssetId public immutable USD_ID = newAssetId(840);
    AssetId public immutable EUR_ID = newAssetId(978);
}

abstract contract BaseActionBatcher {
    error NotDeployer();

    address public deployer;

    constructor(address deployer_) {
        deployer = deployer_;
    }

    modifier onlyDeployer() {
        require(msg.sender == deployer, NotDeployer());
        _;
    }
}

contract CoreActionBatcher is BaseActionBatcher, Constants {
    constructor(address deployer_) BaseActionBatcher(deployer_) {}

    function setupCore(
        CoreReport memory report,
        ISafe protocolSafe,
        ISafe opsSafe,
        address adapterBatcher_,
        address nonCoreBatcher_
    ) public onlyDeployer {
        address root = address(report.root);

        // Rely root
        report.gateway.rely(root);
        report.multiAdapter.rely(root);

        report.messageDispatcher.rely(root);
        report.messageProcessor.rely(root);

        report.poolEscrowFactory.rely(root);
        report.tokenFactory.rely(root);
        report.spoke.rely(root);
        report.balanceSheet.rely(root);
        report.contractUpdater.rely(root);
        report.vaultRegistry.rely(root);

        report.hubRegistry.rely(root);
        report.accounting.rely(root);
        report.holdings.rely(root);
        report.shareClassManager.rely(root);
        report.hub.rely(root);
        report.hubHandler.rely(root);

        report.tokenRecoverer.rely(root);

        // Rely gateway
        report.multiAdapter.rely(address(report.gateway));
        report.messageProcessor.rely(address(report.gateway));

        // Rely multiAdapter
        report.gateway.rely(address(report.multiAdapter));

        // Rely messageDispatcher
        report.gateway.rely(address(report.messageDispatcher));
        report.spoke.rely(address(report.messageDispatcher));
        report.balanceSheet.rely(address(report.messageDispatcher));
        report.contractUpdater.rely(address(report.messageDispatcher));
        report.vaultRegistry.rely(address(report.messageDispatcher));
        report.hubHandler.rely(address(report.messageDispatcher));
        report.root.rely(address(report.messageDispatcher));
        report.tokenRecoverer.rely(address(report.messageDispatcher));

        // Rely messageProcessor
        report.gateway.rely(address(report.messageProcessor));
        report.multiAdapter.rely(address(report.messageProcessor));
        report.spoke.rely(address(report.messageProcessor));
        report.balanceSheet.rely(address(report.messageProcessor));
        report.contractUpdater.rely(address(report.messageProcessor));
        report.vaultRegistry.rely(address(report.messageProcessor));
        report.hubHandler.rely(address(report.messageProcessor));
        report.root.rely(address(report.messageProcessor));
        report.tokenRecoverer.rely(address(report.messageProcessor));

        // Rely spoke
        report.gateway.rely(address(report.spoke));
        report.messageDispatcher.rely(address(report.spoke));
        report.tokenFactory.rely(address(report.spoke));
        report.poolEscrowFactory.rely(address(report.spoke));

        // Rely balanceSheet
        report.messageDispatcher.rely(address(report.balanceSheet));

        // Rely vaultRegistry
        report.spoke.rely(address(report.vaultRegistry));

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
        report.gateway.rely(address(report.protocolGuardian));
        report.multiAdapter.rely(address(report.protocolGuardian));
        report.messageDispatcher.rely(address(report.protocolGuardian));
        report.root.rely(address(report.protocolGuardian));
        report.tokenRecoverer.rely(address(report.protocolGuardian));

        // Rely opsGuardian
        report.multiAdapter.rely(address(report.opsGuardian));
        report.hub.rely(address(report.opsGuardian));

        // Rely tokenRecoverer
        report.root.rely(address(report.tokenRecoverer));

        // File methods
        report.gateway.file("adapter", address(report.multiAdapter));
        report.gateway.file("messageProperties", address(report.gasService));
        report.gateway.file("processor", address(report.messageProcessor));

        report.multiAdapter.file("messageProperties", address(report.gasService));

        report.messageDispatcher.file("spoke", address(report.spoke));
        report.messageDispatcher.file("balanceSheet", address(report.balanceSheet));
        report.messageDispatcher.file("contractUpdater", address(report.contractUpdater));
        report.messageDispatcher.file("vaultRegistry", address(report.vaultRegistry));
        report.messageDispatcher.file("hubHandler", address(report.hubHandler));
        report.messageDispatcher.file("tokenRecoverer", address(report.tokenRecoverer));

        report.messageProcessor.file("multiAdapter", address(report.multiAdapter));
        report.messageProcessor.file("gateway", address(report.gateway));
        report.messageProcessor.file("spoke", address(report.spoke));
        report.messageProcessor.file("balanceSheet", address(report.balanceSheet));
        report.messageProcessor.file("contractUpdater", address(report.contractUpdater));
        report.messageProcessor.file("vaultRegistry", address(report.vaultRegistry));
        report.messageProcessor.file("hubHandler", address(report.hubHandler));
        report.messageProcessor.file("tokenRecoverer", address(report.tokenRecoverer));

        report.poolEscrowFactory.file("balanceSheet", address(report.balanceSheet));

        report.spoke.file("gateway", address(report.gateway));
        report.spoke.file("poolEscrowFactory", address(report.poolEscrowFactory));
        report.spoke.file("sender", address(report.messageDispatcher));

        report.balanceSheet.file("spoke", address(report.spoke));
        report.balanceSheet.file("gateway", address(report.gateway));
        report.balanceSheet.file("poolEscrowProvider", address(report.poolEscrowFactory));
        report.balanceSheet.file("sender", address(report.messageDispatcher));

        report.vaultRegistry.file("spoke", address(report.spoke));

        report.hub.file("sender", address(report.messageDispatcher));

        report.hubHandler.file("sender", address(report.messageDispatcher));

        report.opsGuardian.file("opsSafe", address(opsSafe));
        report.protocolGuardian.file("safe", address(protocolSafe));

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(report.spoke);
        tokenWards[1] = address(report.balanceSheet);
        report.tokenFactory.file("wards", tokenWards);

        // Endorse methods
        report.root.endorse(address(report.balanceSheet));

        // Initial configuration
        report.hubRegistry.registerAsset(USD_ID, ISO4217_DECIMALS);
        report.hubRegistry.registerAsset(EUR_ID, ISO4217_DECIMALS);

        // Other batchers
        report.multiAdapter.rely(adapterBatcher_);
        report.root.rely(nonCoreBatcher_);

        // Revoke batcher permissions
        report.gateway.deny(address(this));
        report.multiAdapter.deny(address(this));

        report.messageProcessor.deny(address(this));
        report.messageDispatcher.deny(address(this));

        report.spoke.deny(address(this));
        report.balanceSheet.deny(address(this));
        report.tokenFactory.deny(address(this));
        report.contractUpdater.deny(address(this));
        report.vaultRegistry.deny(address(this));
        report.poolEscrowFactory.deny(address(this));

        report.hubRegistry.deny(address(this));
        report.accounting.deny(address(this));
        report.holdings.deny(address(this));
        report.shareClassManager.deny(address(this));
        report.hub.deny(address(this));
        report.hubHandler.deny(address(this));

        report.root.deny(address(this));
        report.tokenRecoverer.deny(address(this));

        deployer = address(0);
    }
}

contract NonCoreActionBatcher is BaseActionBatcher {
    constructor(address deployer_) BaseActionBatcher(deployer_) {}

    function setupNonCore(NonCoreReport memory report) public onlyDeployer {
        address root = address(report.core.root);

        // Rely Root
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

        // Rely spoke
        report.asyncRequestManager.rely(address(report.core.spoke));
        report.freezeOnlyHook.rely(address(report.core.spoke));
        report.fullRestrictionsHook.rely(address(report.core.spoke));
        report.freelyTransferableHook.rely(address(report.core.spoke));
        report.redemptionRestrictionsHook.rely(address(report.core.spoke));

        // Rely vaultRegistry
        report.asyncVaultFactory.rely(address(report.core.vaultRegistry));
        report.syncDepositVaultFactory.rely(address(report.core.vaultRegistry));

        // Rely contractUpdater
        report.syncManager.rely(address(report.core.contractUpdater));
        report.asyncRequestManager.rely(address(report.core.contractUpdater));

        // Rely hub
        report.batchRequestManager.rely(address(report.core.hub));

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

        report.asyncRequestManager.file("spoke", address(report.core.spoke));
        report.asyncRequestManager.file("balanceSheet", address(report.core.balanceSheet));
        report.asyncRequestManager.file("vaultRegistry", address(report.core.vaultRegistry));

        report.syncManager.file("spoke", address(report.core.spoke));
        report.syncManager.file("balanceSheet", address(report.core.balanceSheet));
        report.syncManager.file("vaultRegistry", address(report.core.vaultRegistry));

        report.batchRequestManager.file("hub", address(report.core.hub));

        // Endorse methods
        report.core.root.endorse(address(report.asyncRequestManager));
        report.core.root.endorse(address(report.vaultRouter));

        // Revoke batcher permissions
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

        report.core.root.deny(address(this));

        deployer = address(0);
    }
}

contract AdapterActionBatcher is BaseActionBatcher {
    constructor(address deployer_) BaseActionBatcher(deployer_) {}

    function setupAdapters(
        AdaptersReport memory report,
        ISafe protocolSafe,
        AdapterConnections[] memory connectionList,
        SetConfigParam[] memory layerZeroConfigParams,
        address layerZeroDelegate,
        string memory remoteAxelarAdapter
    ) public onlyDeployer {
        _relyAdapters(report, address(report.core.root));
        _relyAdapters(report, address(report.core.protocolGuardian));
        _relyAdapters(report, address(report.core.opsGuardian));

        // Rely protocolSafe on LayerZero (needed for setDelegate calls)
        if (address(report.layerZeroAdapter) != address(0)) {
            report.layerZeroAdapter.rely(address(protocolSafe));
        }

        // Connect adapters
        for (uint256 i; i < connectionList.length; i++) {
            AdapterConnections memory connections = connectionList[i];

            uint256 n;
            IAdapter[] memory adapters = new IAdapter[](MAX_ADAPTER_COUNT);

            if (address(report.layerZeroAdapter) != address(0) && connections.layerZeroId != 0) {
                report.layerZeroAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.layerZeroId, report.layerZeroAdapter));
                adapters[n++] = report.layerZeroAdapter;

                if (layerZeroConfigParams.length > 0) {
                    _setLayerZeroUlnConfig(report.layerZeroAdapter, connections.layerZeroId, layerZeroConfigParams[i]);
                }
            }

            if (address(report.wormholeAdapter) != address(0) && connections.wormholeId != 0) {
                report.wormholeAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.wormholeId, report.wormholeAdapter));
                adapters[n++] = report.wormholeAdapter;
            }

            if (address(report.axelarAdapter) != address(0) && bytes(connections.axelarId).length != 0) {
                report.axelarAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.axelarId, remoteAxelarAdapter));
                adapters[n++] = report.axelarAdapter;
            }

            if (address(report.chainlinkAdapter) != address(0) && connections.chainlinkId != 0) {
                report.chainlinkAdapter
                    .wire(connections.centrifugeId, abi.encode(connections.chainlinkId, report.chainlinkAdapter));

                adapters[n++] = report.chainlinkAdapter;
            }

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
                        uint8(adapters.length)
                    );
            }
        }

        if (address(report.layerZeroAdapter) != address(0)) {
            // Set delegate to the right address after setting the ULN config
            report.layerZeroAdapter.setDelegate(layerZeroDelegate);
        }

        // Revoke batcher permissions
        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.deny(address(this));
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.deny(address(this));
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.deny(address(this));
        if (address(report.chainlinkAdapter) != address(0)) report.chainlinkAdapter.deny(address(this));

        report.core.multiAdapter.deny(address(this));

        deployer = address(0);
    }

    function _relyAdapters(AdaptersReport memory report, address ward) internal {
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.rely(ward);
        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.rely(ward);
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.rely(ward);
        if (address(report.chainlinkAdapter) != address(0)) report.chainlinkAdapter.rely(ward);
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

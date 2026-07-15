// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Hub} from "../../../../../src/core/hub/Hub.sol";
import {Envoy} from "../../../../../src/core/utils/Envoy.sol";
import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {Holdings} from "../../../../../src/core/hub/Holdings.sol";
import {Accounting} from "../../../../../src/core/hub/Accounting.sol";
import {Gateway} from "../../../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../../../../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../../../../src/core/spoke/BalanceSheet.sol";
import {SpokeHandler} from "../../../../../src/core/spoke/SpokeHandler.sol";
import {SpokeRegistry} from "../../../../../src/core/spoke/SpokeRegistry.sol";
import {MultiAdapter} from "../../../../../src/core/messaging/MultiAdapter.sol";
import {SpokeV3_1_0} from "../../../../../src/core/spoke/legacy/SpokeV3_1_0.sol";
import {ContractUpdater} from "../../../../../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../../../../../src/core/hub/ShareClassManager.sol";
import {MessageProcessor} from "../../../../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../../../../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../../../../../src/core/spoke/factories/PoolEscrowFactory.sol";
import {ContractUpdaterForwarder} from "../../../../../src/core/utils/ContractUpdaterForwarder.sol";

import {Root} from "../../../../../src/admin/Root.sol";
import {GasService} from "../../../../../src/admin/GasService.sol";
import {OpsGuardian} from "../../../../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../../../../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../../../../../src/token/hooks/FreezeOnly.sol";
import {NAVManager} from "../../../../../src/hooks/accounting/NAVManager.sol";
import {FullRestrictions} from "../../../../../src/token/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../../../../src/token/hooks/FreelyTransferable.sol";
import {SimplePriceManager} from "../../../../../src/hooks/accounting/SimplePriceManager.sol";
import {RedemptionRestrictions} from "../../../../../src/token/hooks/RedemptionRestrictions.sol";

import {QueueManager} from "../../../../../src/managers/spoke/QueueManager.sol";
import {OnOffRampFactory} from "../../../../../src/managers/spoke/OnOffRamp.sol";

import {OracleValuation} from "../../../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../../../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../../../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../../../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../../../../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../../../../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../../../../../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../../../../../src/vaults/factories/SyncDepositVaultFactory.sol";

import {FullDeployer} from "../../../../../script/FullDeployer.s.sol";
import {ContractsConfig as LiveContracts, EnvConfig} from "../../../../../script/utils/EnvConfig.s.sol";

import {SubsidyManager} from "../../../../../src/utils/SubsidyManager.sol";
import {AxelarAdapter} from "../../../../../src/adapters/AxelarAdapter.sol";
import {ChainlinkAdapter} from "../../../../../src/adapters/ChainlinkAdapter.sol";
import {HyperlaneAdapter} from "../../../../../src/adapters/HyperlaneAdapter.sol";
import {LayerZeroAdapter} from "../../../../../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../../../../../src/utils/RefundEscrowFactory.sol";
import {ShareTokenRegistrar} from "../../../../../src/token/ShareTokenRegistrar.sol";
import {
    CoreReport,
    NonCoreReport as MainContracts,
    AdaptersReport as AdaptersContract
} from "../../../../../src/deployment/ActionBatchers.sol";

/// @notice struct used in validators
struct TestContracts {
    MainContracts main;
    AdaptersContract adapters;
}

function testContractsFromDeployer(FullDeployer deployer) view returns (TestContracts memory) {
    return TestContracts(deployer.nonCoreReport(), deployer.adaptersReport());
}

function testContractsFromConfig(EnvConfig memory config) pure returns (TestContracts memory) {
    LiveContracts memory c = config.contracts;

    CoreReport memory core = CoreReport(
        Gateway(c.gateway),
        MultiAdapter(c.multiAdapter),
        MessageProcessor(c.messageProcessor),
        MessageDispatcher(c.messageDispatcher),
        PoolEscrowFactory(c.poolEscrowFactory),
        Spoke(c.spoke),
        BalanceSheet(c.balanceSheet),
        ShareTokenRegistrar(c.shareTokenRegistrar),
        ContractUpdater(c.contractUpdater),
        SpokeHandler(c.spokeHandler),
        SpokeRegistry(c.spokeRegistry),
        SpokeV3_1_0(c.spokeV3_1_0),
        ContractUpdaterForwarder(c.contractUpdaterForwarder),
        Envoy(c.envoy),
        HubRegistry(c.hubRegistry),
        Accounting(c.accounting),
        Holdings(c.holdings),
        ShareClassManager(c.shareClassManager),
        HubHandler(c.hubHandler),
        Hub(c.hub),
        Root(c.root),
        ProtocolGuardian(c.protocolGuardian),
        OpsGuardian(c.opsGuardian),
        GasService(c.gasService)
    );

    MainContracts memory main = MainContracts(
        core,
        SubsidyManager(c.subsidyManager),
        RefundEscrowFactory(c.refundEscrowFactory),
        AsyncVaultFactory(c.asyncVaultFactory),
        AsyncRequestManager(payable(c.asyncRequestManager)),
        SyncDepositVaultFactory(c.syncDepositVaultFactory),
        SyncManager(c.syncManager),
        VaultRouter(c.vaultRouter),
        FreezeOnly(c.freezeOnlyHook),
        FullRestrictions(c.fullRestrictionsHook),
        FreelyTransferable(c.freelyTransferableHook),
        RedemptionRestrictions(c.redemptionRestrictionsHook),
        QueueManager(c.queueManager),
        OnOffRampFactory(c.onOffRampFactory),
        BatchRequestManager(c.batchRequestManager),
        IdentityValuation(c.identityValuation),
        OracleValuation(c.oracleValuation),
        NAVManager(c.navManager),
        SimplePriceManager(c.simplePriceManager)
    );

    AdaptersContract memory adapters = AdaptersContract(
        core,
        LayerZeroAdapter(c.layerZeroAdapter),
        AxelarAdapter(c.axelarAdapter),
        ChainlinkAdapter(c.chainlinkAdapter),
        HyperlaneAdapter(c.hyperlaneAdapter)
    );

    return TestContracts(main, adapters);
}

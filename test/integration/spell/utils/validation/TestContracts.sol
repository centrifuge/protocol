// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Hub} from "../../../../../src/core/hub/Hub.sol";
import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {Holdings} from "../../../../../src/core/hub/Holdings.sol";
import {Accounting} from "../../../../../src/core/hub/Accounting.sol";
import {Gateway} from "../../../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../../../../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../../../../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../../../../../src/core/messaging/GasService.sol";
import {VaultRegistry} from "../../../../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../../../../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../../../../../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../../../../../src/core/hub/ShareClassManager.sol";
import {TokenFactory} from "../../../../../src/core/spoke/factories/TokenFactory.sol";
import {MessageProcessor} from "../../../../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../../../../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../../../../../src/core/spoke/factories/PoolEscrowFactory.sol";

import {Root} from "../../../../../src/admin/Root.sol";
import {OpsGuardian} from "../../../../../src/admin/OpsGuardian.sol";
import {TokenRecoverer} from "../../../../../src/admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../../../../../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../../../../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../../../../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../../../../src/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../../../../src/hooks/RedemptionRestrictions.sol";

import {NAVManager} from "../../../../../src/managers/hub/NAVManager.sol";
import {QueueManager} from "../../../../../src/managers/spoke/QueueManager.sol";
import {VaultDecoder} from "../../../../../src/managers/spoke/decoders/VaultDecoder.sol";
import {SimplePriceManager} from "../../../../../src/managers/hub/SimplePriceManager.sol";
import {CircleDecoder} from "../../../../../src/managers/spoke/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../../../../../src/managers/spoke/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../../../../../src/managers/spoke/MerkleProofManager.sol";

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
import {WormholeAdapter} from "../../../../../src/adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../../../../../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../../../../../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../../../../../src/utils/RefundEscrowFactory.sol";
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
        GasService(c.gasService),
        MessageProcessor(c.messageProcessor),
        MessageDispatcher(c.messageDispatcher),
        PoolEscrowFactory(c.poolEscrowFactory),
        Spoke(c.spoke),
        BalanceSheet(c.balanceSheet),
        TokenFactory(c.tokenFactory),
        ContractUpdater(c.contractUpdater),
        VaultRegistry(c.vaultRegistry),
        HubRegistry(c.hubRegistry),
        Accounting(c.accounting),
        Holdings(c.holdings),
        ShareClassManager(c.shareClassManager),
        HubHandler(c.hubHandler),
        Hub(c.hub),
        Root(c.root),
        TokenRecoverer(c.tokenRecoverer),
        ProtocolGuardian(c.protocolGuardian),
        OpsGuardian(c.opsGuardian)
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
        OnOfframpManagerFactory(c.onOfframpManagerFactory),
        MerkleProofManagerFactory(c.merkleProofManagerFactory),
        VaultDecoder(c.vaultDecoder),
        CircleDecoder(c.circleDecoder),
        BatchRequestManager(c.batchRequestManager),
        IdentityValuation(c.identityValuation),
        OracleValuation(c.oracleValuation),
        NAVManager(c.navManager),
        SimplePriceManager(c.simplePriceManager)
    );

    AdaptersContract memory adapters = AdaptersContract(
        core,
        LayerZeroAdapter(c.layerZeroAdapter),
        WormholeAdapter(c.wormholeAdapter),
        AxelarAdapter(c.axelarAdapter),
        ChainlinkAdapter(c.chainlinkAdapter)
    );

    return TestContracts(main, adapters);
}

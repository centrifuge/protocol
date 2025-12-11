// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainResolver} from "./ChainResolver.sol";
import {ValidationOrchestrator} from "./validation/ValidationOrchestrator.sol";

import {Escrow} from "../../../src/misc/Escrow.sol";

import {Hub} from "../../../src/core/hub/Hub.sol";
import {Spoke} from "../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";
import {Holdings} from "../../../src/core/hub/Holdings.sol";
import {Accounting} from "../../../src/core/hub/Accounting.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../../../src/core/messaging/GasService.sol";
import {VaultRegistry} from "../../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../../../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../../../src/core/hub/ShareClassManager.sol";
import {TokenFactory} from "../../../src/core/spoke/factories/TokenFactory.sol";
import {MessageProcessor} from "../../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../../../src/core/spoke/factories/PoolEscrowFactory.sol";

import {Root} from "../../../src/admin/Root.sol";
import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../../../src/admin/OpsGuardian.sol";
import {TokenRecoverer} from "../../../src/admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../../../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../../src/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../../src/hooks/RedemptionRestrictions.sol";

import {NAVManager} from "../../../src/managers/hub/NAVManager.sol";
import {QueueManager} from "../../../src/managers/spoke/QueueManager.sol";
import {VaultDecoder} from "../../../src/managers/spoke/decoders/VaultDecoder.sol";
import {SimplePriceManager} from "../../../src/managers/hub/SimplePriceManager.sol";
import {CircleDecoder} from "../../../src/managers/spoke/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../../../src/managers/spoke/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../../../src/managers/spoke/MerkleProofManager.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../../../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../../../src/vaults/factories/SyncDepositVaultFactory.sol";

import {CoreReport} from "../../../script/CoreDeployer.s.sol";
import {MigrationQueries} from "../../../script/spell/MigrationQueries.sol";
import {
    FullActionBatcher,
    FullDeployer,
    FullInput,
    FullReport,
    noAdaptersInput,
    defaultTxLimits,
    CoreInput
} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {SubsidyManager} from "../../../src/utils/SubsidyManager.sol";
import {AxelarAdapter} from "../../../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../../../src/adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../../../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../../../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../../../src/utils/RefundEscrowFactory.sol";
import {ForkTestLiveValidation} from "../../integration/fork/ForkTestLiveValidation.sol";

contract ValidationRunner is Test {
    ISafe immutable ADMIN = ISafe(makeAddr("ADMIN"));
    bytes32 constant NEW_VERSION = "v3.1";

    function validate(
        string memory network,
        string memory rpcUrl,
        address safeAdmin,
        PoolId[] memory poolsToMigrate,
        bool isPre
    ) public {
        vm.createSelectFork(rpcUrl);

        string memory configFile = string.concat("env/", network, ".json");
        string memory config = vm.readFile(configFile);

        string memory environment = vm.parseJsonString(config, "$.network.environment");
        bool isMainnet = keccak256(bytes(environment)) != keccak256("testnet");

        ChainResolver.ChainContext memory chain = ChainResolver.resolveChainContext(isMainnet);
        MigrationQueries queryService = new MigrationQueries(isMainnet);
        queryService.configureGraphQl(chain.graphQLApi, chain.localCentrifugeId);
        ValidationOrchestrator.SharedContext memory shared =
            ValidationOrchestrator.buildSharedContext(queryService, poolsToMigrate, chain, "");

        FullReport memory latest = _reportFromJson(config);

        if (isPre) {
            ValidationOrchestrator.runPreValidation(shared, false); // shouldRevert = false (show warnings)
        } else {
            ValidationOrchestrator.runPostValidation(shared, latest);
        }

        ForkTestLiveValidation validator = new ForkTestLiveValidation();
        validator.loadContractsFromDeployer(latest, safeAdmin);
        validator.validateDeployment(isPre, isMainnet);
    }

    function _reportFromJson(string memory config) private pure returns (FullReport memory report) {
        // Build CoreReport
        CoreReport memory core = CoreReport({
            gateway: Gateway(vm.parseJsonAddress(config, "$.contracts.gateway")),
            multiAdapter: MultiAdapter(vm.parseJsonAddress(config, "$.contracts.multiAdapter")),
            gasService: GasService(vm.parseJsonAddress(config, "$.contracts.gasService")),
            messageProcessor: MessageProcessor(vm.parseJsonAddress(config, "$.contracts.messageProcessor")),
            messageDispatcher: MessageDispatcher(vm.parseJsonAddress(config, "$.contracts.messageDispatcher")),
            poolEscrowFactory: PoolEscrowFactory(vm.parseJsonAddress(config, "$.contracts.poolEscrowFactory")),
            spoke: Spoke(vm.parseJsonAddress(config, "$.contracts.spoke")),
            balanceSheet: BalanceSheet(vm.parseJsonAddress(config, "$.contracts.balanceSheet")),
            tokenFactory: TokenFactory(vm.parseJsonAddress(config, "$.contracts.tokenFactory")),
            contractUpdater: ContractUpdater(vm.parseJsonAddress(config, "$.contracts.contractUpdater")),
            vaultRegistry: VaultRegistry(_tryParseAddress(config, "$.contracts.vaultRegistry")),
            hubRegistry: HubRegistry(vm.parseJsonAddress(config, "$.contracts.hubRegistry")),
            accounting: Accounting(vm.parseJsonAddress(config, "$.contracts.accounting")),
            holdings: Holdings(vm.parseJsonAddress(config, "$.contracts.holdings")),
            shareClassManager: ShareClassManager(vm.parseJsonAddress(config, "$.contracts.shareClassManager")),
            hubHandler: HubHandler(_tryParseAddress(config, "$.contracts.hubHandler")),
            hub: Hub(vm.parseJsonAddress(config, "$.contracts.hub"))
        });

        // Build FullReport
        report = FullReport({
            core: core,
            root: Root(vm.parseJsonAddress(config, "$.contracts.root")),
            tokenRecoverer: TokenRecoverer(vm.parseJsonAddress(config, "$.contracts.tokenRecoverer")),
            protocolGuardian: ProtocolGuardian(_tryParseAddress(config, "$.contracts.protocolGuardian")),
            opsGuardian: OpsGuardian(_tryParseAddress(config, "$.contracts.opsGuardian")),
            routerEscrow: Escrow(vm.parseJsonAddress(config, "$.contracts.routerEscrow")),
            subsidyManager: SubsidyManager(_tryParseAddress(config, "$.contracts.subsidyManager")),
            refundEscrowFactory: RefundEscrowFactory(_tryParseAddress(config, "$.contracts.refundEscrowFactory")),
            asyncVaultFactory: AsyncVaultFactory(vm.parseJsonAddress(config, "$.contracts.asyncVaultFactory")),
            asyncRequestManager: AsyncRequestManager(
                payable(vm.parseJsonAddress(config, "$.contracts.asyncRequestManager"))
            ),
            syncDepositVaultFactory: SyncDepositVaultFactory(
                vm.parseJsonAddress(config, "$.contracts.syncDepositVaultFactory")
            ),
            syncManager: SyncManager(vm.parseJsonAddress(config, "$.contracts.syncManager")),
            vaultRouter: VaultRouter(vm.parseJsonAddress(config, "$.contracts.vaultRouter")),
            freezeOnlyHook: FreezeOnly(vm.parseJsonAddress(config, "$.contracts.freezeOnlyHook")),
            fullRestrictionsHook: FullRestrictions(vm.parseJsonAddress(config, "$.contracts.fullRestrictionsHook")),
            freelyTransferableHook: FreelyTransferable(
                vm.parseJsonAddress(config, "$.contracts.freelyTransferableHook")
            ),
            redemptionRestrictionsHook: RedemptionRestrictions(
                vm.parseJsonAddress(config, "$.contracts.redemptionRestrictionsHook")
            ),
            queueManager: QueueManager(_tryParseAddress(config, "$.contracts.queueManager")),
            onOfframpManagerFactory: OnOfframpManagerFactory(
                vm.parseJsonAddress(config, "$.contracts.onOfframpManagerFactory")
            ),
            merkleProofManagerFactory: MerkleProofManagerFactory(
                vm.parseJsonAddress(config, "$.contracts.merkleProofManagerFactory")
            ),
            vaultDecoder: VaultDecoder(vm.parseJsonAddress(config, "$.contracts.vaultDecoder")),
            circleDecoder: CircleDecoder(vm.parseJsonAddress(config, "$.contracts.circleDecoder")),
            batchRequestManager: BatchRequestManager(_tryParseAddress(config, "$.contracts.batchRequestManager")),
            identityValuation: IdentityValuation(vm.parseJsonAddress(config, "$.contracts.identityValuation")),
            oracleValuation: OracleValuation(_tryParseAddress(config, "$.contracts.oracleValuation")),
            navManager: NAVManager(_tryParseAddress(config, "$.contracts.navManager")),
            simplePriceManager: SimplePriceManager(_tryParseAddress(config, "$.contracts.simplePriceManager")),
            wormholeAdapter: WormholeAdapter(_tryParseAddress(config, "$.contracts.wormholeAdapter")),
            axelarAdapter: AxelarAdapter(_tryParseAddress(config, "$.contracts.axelarAdapter")),
            layerZeroAdapter: LayerZeroAdapter(_tryParseAddress(config, "$.contracts.layerZeroAdapter")),
            chainlinkAdapter: ChainlinkAdapter(_tryParseAddress(config, "$.contracts.chainlinkAdapter"))
        });
    }

    /// @notice Attempts to parse an address from JSON, returns address(0) if key doesn't exist
    function _tryParseAddress(string memory config, string memory key) private pure returns (address) {
        try vm.parseJsonAddress(config, key) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }
}

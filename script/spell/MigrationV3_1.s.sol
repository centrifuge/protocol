// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MigrationQueries} from "./MigrationQueries.sol";

import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../src/core/types/PoolId.sol";
import {HubRegistry} from "../../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../src/core/spoke/BalanceSheet.sol";
import {VaultRegistry} from "../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../../src/core/hub/ShareClassManager.sol";
import {MessageProcessor} from "../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../src/core/messaging/MessageDispatcher.sol";

import {Root} from "../../src/admin/Root.sol";
import {TokenRecoverer} from "../../src/admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../src/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../src/hooks/RedemptionRestrictions.sol";

import {OnOfframpManagerFactory} from "../../src/managers/spoke/OnOfframpManager.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../src/vaults/BatchRequestManager.sol";

import "forge-std/Script.sol";

import {makeSalt} from "../CoreDeployer.s.sol";
import {CreateXScript} from "../utils/CreateXScript.sol";
import {GraphQLConstants} from "../utils/GraphQLConstants.sol";
import {
    MigrationSpell,
    PoolParamsInput,
    GlobalParamsInput,
    PoolMigrationOldContracts,
    GlobalMigrationOldContracts
} from "../../src/spell/migration_v3.1/MigrationSpell.sol";

contract MigrationV3_1Deployer is Script {
    function run() external {
        vm.startBroadcast();

        new MigrationSpell(msg.sender);

        vm.stopBroadcast();
    }
}

contract MigrationV3_1Executor is Script, CreateXScript {
    bytes32 constant NEW_VERSION = "v3.1";

    address deployer;

    bool public immutable isMainnet;
    string public graphQLApi;

    MigrationQueries public queryService;

    constructor(bool isMainnet_) {
        isMainnet = isMainnet_;
        graphQLApi = isMainnet_ ? GraphQLConstants.PRODUCTION_API : GraphQLConstants.TESTNET_API;
    }

    receive() external payable {}

    function run(MigrationSpell migrationSpell, PoolId[] memory poolsToMigrate) external {
        vm.startBroadcast();

        migrate(msg.sender, migrationSpell, poolsToMigrate);

        vm.stopBroadcast();
    }

    function migrate(address deployer_, MigrationSpell migrationSpell, PoolId[] memory poolsToMigrate) public {
        deployer = deployer_; // This must be set before _contractAddr
        uint16 centrifugeId = MessageDispatcher(_contractAddr("messageDispatcher")).localCentrifugeId();

        // Create query service
        queryService = new MigrationQueries(graphQLApi, centrifugeId, isMainnet);

        Root root = queryService.root();
        vm.label(address(root), "v3.root");
        vm.label(address(migrationSpell), "migrationSpell");

        GlobalMigrationOldContracts memory globalV3 = queryService.globalMigrationOldContracts();
        vm.label(address(globalV3.gateway), "v3.gateway");
        vm.label(address(globalV3.spoke), "v3.spoke");
        vm.label(address(globalV3.hubRegistry), "v3.hubRegistry");
        vm.label(address(globalV3.asyncRequestManager), "v3.asyncRequestManager");
        vm.label(address(globalV3.syncManager), "v3.syncManager");

        migrationSpell.castGlobal(
            GlobalParamsInput({
                v3: globalV3,
                root: root,
                spoke: Spoke(_contractAddr("spoke")),
                balanceSheet: BalanceSheet(_contractAddr("balanceSheet")),
                hubRegistry: HubRegistry(_contractAddr("hubRegistry")),
                multiAdapter: MultiAdapter(_contractAddr("multiAdapter")),
                messageDispatcher: MessageDispatcher(_contractAddr("messageDispatcher")),
                messageProcessor: MessageProcessor(_contractAddr("messageProcessor")),
                asyncRequestManager: AsyncRequestManager(payable(_contractAddr("asyncRequestManager"))),
                syncManager: SyncManager(_contractAddr("syncManager")),
                protocolGuardian: ProtocolGuardian(_contractAddr("protocolGuardian")),
                tokenRecoverer: TokenRecoverer(_contractAddr("tokenRecoverer")),
                vaultRouter: VaultRouter(_contractAddr("vaultRouter")),
                spokeAssetIds: queryService.spokeAssetIds(),
                hubAssetIds: queryService.hubAssetIds(),
                vaults: queryService.vaults()
            })
        );

        PoolMigrationOldContracts memory poolV3 = queryService.poolMigrationOldContracts();
        vm.label(address(poolV3.gateway), "v3.gateway");
        vm.label(address(poolV3.poolEscrowFactory), "v3.poolEscrowFactory");
        vm.label(address(poolV3.spoke), "v3.spoke");
        vm.label(address(poolV3.balanceSheet), "v3.balanceSheet");
        vm.label(address(poolV3.hubRegistry), "v3.hubRegistry");
        vm.label(address(poolV3.shareClassManager), "v3.shareClassManager");
        vm.label(address(poolV3.asyncVaultFactory), "v3.asyncVaultFactory");
        vm.label(address(poolV3.asyncRequestManager), "v3.asyncRequestManager");
        vm.label(address(poolV3.syncDepositVaultFactory), "v3.syncDepositVaultFactory");
        vm.label(address(poolV3.syncManager), "v3.syncManager");
        vm.label(address(poolV3.freezeOnly), "v3.freezeOnly");
        vm.label(address(poolV3.fullRestrictions), "v3.fullRestrictions");
        vm.label(address(poolV3.freelyTransferable), "v3.freelyTransferable");
        vm.label(address(poolV3.redemptionRestrictions), "v3.redemptionRestrictions");

        for (uint256 i; i < poolsToMigrate.length; i++) {
            PoolId poolId = poolsToMigrate[i];

            migrationSpell.castPool(
                poolId,
                PoolParamsInput({
                    v3: poolV3,
                    root: root,
                    spoke: Spoke(_contractAddr("spoke")),
                    balanceSheet: BalanceSheet(_contractAddr("balanceSheet")),
                    vaultRegistry: VaultRegistry(_contractAddr("vaultRegistry")),
                    hubRegistry: HubRegistry(_contractAddr("hubRegistry")),
                    shareClassManager: ShareClassManager(_contractAddr("shareClassManager")),
                    asyncRequestManager: AsyncRequestManager(payable(_contractAddr("asyncRequestManager"))),
                    syncManager: SyncManager(_contractAddr("syncManager")),
                    freezeOnly: FreezeOnly(_contractAddr("freezeOnlyHook")),
                    fullRestrictions: FullRestrictions(_contractAddr("fullRestrictionsHook")),
                    freelyTransferable: FreelyTransferable(_contractAddr("freelyTransferableHook")),
                    redemptionRestrictions: RedemptionRestrictions(_contractAddr("redemptionRestrictionsHook")),
                    onOfframpManagerFactory: OnOfframpManagerFactory(_contractAddr("onOfframpManagerFactory")),
                    batchRequestManager: BatchRequestManager(_contractAddr("batchRequestManager")),
                    contractUpdater: ContractUpdater(_contractAddr("contractUpdater")),
                    spokeAssetIds: queryService.spokeAssetIds(),
                    hubAssetIds: queryService.hubAssetIds(),
                    vaults: queryService.vaults(),
                    assets: queryService.assets(),
                    hubManagers: queryService.hubManagers(poolId),
                    bsManagers: queryService.bsManagers(poolId),
                    onOfframpManagerV3: queryService.onOfframpManagerV3(poolId),
                    onOfframpReceivers: queryService.onOfframpReceivers(poolId),
                    onOfframpRelayers: queryService.onOfframpRelayers(poolId),
                    chainsWherePoolIsNotified: queryService.chainsWherePoolIsNotified(poolId)
                })
            );
        }

        migrationSpell.lock(root);
    }

    function _contractAddr(string memory contractName) internal returns (address addr) {
        addr = computeCreate3Address(makeSalt(contractName, NEW_VERSION, deployer), deployer);
        vm.label(addr, contractName);
    }
}

contract MigrationV3_1ExecutorMainnet is MigrationV3_1Executor {
    constructor() MigrationV3_1Executor(true) {}
}

contract MigrationV3_1ExecutorTestnet is MigrationV3_1Executor {
    constructor() MigrationV3_1Executor(false) {}
}

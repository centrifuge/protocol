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
import {Safe, Enum} from "safe-utils/Safe.sol";

import {makeSalt} from "../CoreDeployer.s.sol";
import {CreateXScript} from "../utils/CreateXScript.sol";
import {GraphQLConstants} from "../utils/GraphQLConstants.sol";
import {RefundEscrowFactory} from "../../src/utils/RefundEscrowFactory.sol";
import {
    MigrationSpell,
    PoolParamsInput,
    GlobalParamsInput,
    V3Contracts
} from "../../src/spell/migration_v3.1/MigrationSpell.sol";

contract MigrationV3_1Deployer is Script {
    function run(address owner) external {
        vm.startBroadcast();

        new MigrationSpell(owner);

        vm.stopBroadcast();
    }
}

contract MigrationV3_1Executor is Script, CreateXScript, MigrationQueries {
    using Safe for *;

    bytes32 constant NEW_VERSION = "v3.1";
    MigrationSpell migrationSpell;
    address deployer;
    string ledgerDerivationPath;
    Safe.Client safe;

    constructor(bool isMainnet_) MigrationQueries(isMainnet_) {}

    receive() external payable {}

    function run(address deployer_, string memory ledgerDerivationPath_, MigrationSpell migrationSpell_) external {
        vm.startBroadcast();

        migrate(deployer_, ledgerDerivationPath_, migrationSpell_);

        vm.stopBroadcast();
    }

    function migrate(address deployer_, string memory ledgerDerivationPath_, MigrationSpell migrationSpell_) public {
        migrationSpell = migrationSpell_;
        deployer = deployer_; // This must be set before _contractAddr
        ledgerDerivationPath = ledgerDerivationPath_;

        string memory graphQLApi = isMainnet ? GraphQLConstants.PRODUCTION_API : GraphQLConstants.TESTNET_API;
        configureGraphQl(graphQLApi, MessageDispatcher(_contractAddr("messageDispatcher")).localCentrifugeId());

        if (bytes(ledgerDerivationPath).length > 0) {
            safe.initialize(msg.sender);
        }

        vm.label(address(migrationSpell), "migrationSpell");

        V3Contracts memory v3 = v3Contracts();
        vm.label(address(v3.root), "v3.root");
        vm.label(address(v3.gateway), "v3.gateway");
        vm.label(address(v3.poolEscrowFactory), "v3.poolEscrowFactory");
        vm.label(address(v3.spoke), "v3.spoke");
        vm.label(address(v3.balanceSheet), "v3.balanceSheet");
        vm.label(address(v3.hubRegistry), "v3.hubRegistry");
        vm.label(address(v3.shareClassManager), "v3.shareClassManager");
        vm.label(address(v3.asyncVaultFactory), "v3.asyncVaultFactory");
        vm.label(address(v3.asyncRequestManager), "v3.asyncRequestManager");
        vm.label(address(v3.syncDepositVaultFactory), "v3.syncDepositVaultFactory");
        vm.label(address(v3.syncManager), "v3.syncManager");
        vm.label(address(v3.freezeOnly), "v3.freezeOnly");
        vm.label(address(v3.fullRestrictions), "v3.fullRestrictions");
        vm.label(address(v3.freelyTransferable), "v3.freelyTransferable");
        vm.label(address(v3.redemptionRestrictions), "v3.redemptionRestrictions");

        GlobalParamsInput memory globalParamsInput = GlobalParamsInput({
            v3: v3,
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
            spokeAssetIds: spokeAssetIds(),
            hubAssetIds: hubAssetIds(),
            vaults: vaults()
        });

        _spellCall(abi.encodeCall(MigrationSpell.castGlobal, (globalParamsInput)));

        PoolId[] memory poolsToMigrate = pools();
        for (uint256 i; i < poolsToMigrate.length; i++) {
            PoolId poolId = poolsToMigrate[i];

            bool inHub = HubRegistry(v3.hubRegistry).exists(poolId);
            bool inSpoke = Spoke(v3.spoke).isPoolActive(poolId);

            if (inHub || inSpoke) {
                PoolParamsInput memory poolParamsInput = PoolParamsInput({
                    v3: v3,
                    multiAdapter: MultiAdapter(_contractAddr("multiAdapter")),
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
                    refundEscrowFactory: RefundEscrowFactory(_contractAddr("refundEscrowFactory")),
                    spokeAssetIds: spokeAssetIds(),
                    hubAssetIds: hubAssetIds(),
                    vaults: vaults(),
                    assets: assets(),
                    hubManagers: hubManagers(poolId),
                    bsManagers: bsManagers(poolId),
                    onOfframpManagerV3: onOfframpManagerV3(poolId),
                    onOfframpReceivers: onOfframpReceivers(poolId),
                    onOfframpRelayers: onOfframpRelayers(poolId),
                    chainsWherePoolIsNotified: chainsWherePoolIsNotified(poolId)
                });

                _spellCall(abi.encodeCall(MigrationSpell.castPool, (poolId, poolParamsInput)));
            }
        }

        _spellCall(abi.encodeCall(MigrationSpell.lock, (v3.root)));
    }

    function _spellCall(bytes memory data) internal {
        if (bytes(ledgerDerivationPath).length > 0) {
            safe.proposeTransactionWithSignature(
                address(migrationSpell),
                data,
                msg.sender,
                safe.sign(address(migrationSpell), data, Enum.Operation.Call, msg.sender, ledgerDerivationPath)
            );
        } else {
            (bool success, bytes memory returnData) = address(migrationSpell).call(data);
            if (!success) assembly { revert(add(returnData, 32), mload(returnData)) }
        }
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

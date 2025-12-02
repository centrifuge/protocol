// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
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

import {OnOfframpManagerFactory, OnOfframpManager} from "../../src/managers/spoke/OnOfframpManager.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../src/vaults/BatchRequestManager.sol";

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {makeSalt} from "../CoreDeployer.s.sol";
import {CreateXScript} from "../utils/CreateXScript.sol";
import {GraphQLQuery} from "../utils/GraphQLQuery.s.sol";
import {
    AssetInfo,
    MigrationSpell,
    PoolParamsInput,
    PoolMigrationOldContracts,
    GlobalParamsInput,
    GlobalMigrationOldContracts
} from "../../src/spell/migration_v3.1/MigrationSpell.sol";

contract MigrationV3_1Deployer is Script {
    function run() external {
        vm.startBroadcast();

        new MigrationSpell(msg.sender);

        vm.stopBroadcast();
    }
}

contract MigrationV3_1Executor is Script, CreateXScript, GraphQLQuery {
    using stdJson for string;

    bytes32 constant NEW_VERSION = "v3.1";
    uint16 centrifugeId;
    address deployer;

    constructor(bool isProduction) GraphQLQuery(isProduction) {}

    receive() external payable {}

    function run(MigrationSpell migrationSpell, PoolId[] memory poolsToMigrate) external {
        vm.startBroadcast();

        migrate(msg.sender, migrationSpell, poolsToMigrate);

        vm.stopBroadcast();
    }

    function migrate(address deployer_, MigrationSpell migrationSpell, PoolId[] memory poolsToMigrate) public {
        deployer = deployer_; // This must be set before _contractAddr
        centrifugeId = MessageDispatcher(_contractAddr("messageDispatcher")).localCentrifugeId();
        Root root = _root();
        vm.label(address(root), "v3.root");
        vm.label(address(migrationSpell), "migrationSpell");

        GlobalMigrationOldContracts memory globalV3 = _globalMigrationOldContracts();
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
                spokeAssetIds: _spokeAssetIds(),
                hubAssetIds: _hubAssetIds(),
                vaults: _vaults()
            })
        );

        PoolMigrationOldContracts memory poolV3 = _poolMigrationOldContracts();
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
                    spokeAssetIds: _spokeAssetIds(),
                    hubAssetIds: _hubAssetIds(),
                    vaults: _vaults(),
                    assets: _assets(),
                    hubManagers: _hubManagers(poolId),
                    bsManagers: _bsManagers(poolId),
                    onOfframpManagerV3: _onOfframpManagerV3(poolId),
                    onOfframpReceivers: _onOfframpReceivers(poolId),
                    onOfframpRelayers: _onOfframpRelayers(poolId),
                    chainsWherePoolIsNotified: _chainsWherePoolIsNotified(poolId)
                })
            );
        }

        migrationSpell.lock(root);
    }

    function _contractAddr(string memory contractName) internal returns (address addr) {
        addr = computeCreate3Address(makeSalt(contractName, NEW_VERSION, deployer), deployer);
        vm.label(addr, contractName);
    }

    function _root()
        internal
        returns (Root)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", where, ") {",
            "  items {"
            "    root"
            "  }"
            "}"
        ));

        return Root(json.readAddress(".data.deployments.items[0].root"));
    }

    function _globalMigrationOldContracts()
        internal
        returns (GlobalMigrationOldContracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", where, ") {",
            "  items {"
            "    gateway"
            "    spoke"
            "    hubRegistry"
            "    asyncRequestManager"
            "    syncManager"
            "  }"
            "}"
        ));

        v3.gateway = json.readAddress(".data.deployments.items[0].gateway");
        v3.spoke = json.readAddress(".data.deployments.items[0].spoke");
        v3.hubRegistry = json.readAddress(".data.deployments.items[0].hubRegistry");
        v3.asyncRequestManager = json.readAddress(".data.deployments.items[0].asyncRequestManager");
        v3.syncManager = json.readAddress(".data.deployments.items[0].syncManager");
    }

    function _poolMigrationOldContracts()
        internal
        returns (PoolMigrationOldContracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", where, ") {",
            "  items {"
            "    gateway"
            "    poolEscrowFactory"
            "    spoke"
            "    balanceSheet"
            "    hubRegistry"
            "    shareClassManager"
            "    asyncVaultFactory"
            "    asyncRequestManager"
            "    syncDepositVaultFactory"
            "    syncManager"
            "    freezeOnlyHook"
            "    fullRestrictionsHook", (isProduction) ?
            "    freelyTransferableHook" : "",
            "    redemptionRestrictionsHook"
            "  }"
            "}"
        ));

        v3.gateway = json.readAddress(".data.deployments.items[0].gateway");
        v3.poolEscrowFactory = json.readAddress(".data.deployments.items[0].poolEscrowFactory");
        v3.spoke = json.readAddress(".data.deployments.items[0].spoke");
        v3.balanceSheet = json.readAddress(".data.deployments.items[0].balanceSheet");
        v3.hubRegistry = json.readAddress(".data.deployments.items[0].hubRegistry");
        v3.shareClassManager = json.readAddress(".data.deployments.items[0].shareClassManager");
        v3.asyncVaultFactory = json.readAddress(".data.deployments.items[0].asyncVaultFactory");
        v3.asyncRequestManager = json.readAddress(".data.deployments.items[0].asyncRequestManager");
        v3.syncDepositVaultFactory = json.readAddress(".data.deployments.items[0].syncDepositVaultFactory");
        v3.syncManager = json.readAddress(".data.deployments.items[0].syncManager");
        v3.freezeOnly = json.readAddress(".data.deployments.items[0].freezeOnlyHook");
        v3.fullRestrictions = json.readAddress(".data.deployments.items[0].fullRestrictionsHook");
        if (isProduction) {
            v3.freelyTransferable = json.readAddress(".data.deployments.items[0].freelyTransferableHook");
        } else {
            v3.freelyTransferable = address(0xDEAD); // Not deployed in testnets
        }
        v3.redemptionRestrictions = json.readAddress(".data.deployments.items[0].redemptionRestrictionsHook");
    }

    function _spokeAssetIds()
        internal
        returns (AssetId[] memory assetIds)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assets(", where, ") {",
            "  totalCount"
            "  items {"
            "    id"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.assets.totalCount");

        assetIds = new AssetId[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assetIds[i] = AssetId.wrap(uint128(json.readUint(_buildJsonPath(".data.assets.items", i, "id"))));
        }
    }

    function _hubAssetIds()
        internal
        returns (AssetId[] memory assetIds)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assetRegistrations(", where, ") {",
            "  totalCount"
            "  items {"
            "    assetId"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.assetRegistrations.totalCount");

        assetIds = new AssetId[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assetIds[i] =
                AssetId.wrap(uint128(json.readUint(_buildJsonPath(".data.assetRegistrations.items", i, "assetId"))));
        }
    }

    function _vaults()
        internal
        returns (address[] memory vaults)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "vaults(", where, ") {",
            "  totalCount"
            "  items {"
            "    id"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.vaults.totalCount");

        vaults = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            vaults[i] = json.readAddress(_buildJsonPath(".data.vaults.items", i, "id"));
        }
    }

    function _assets()
        internal
        returns (AssetInfo[] memory assets)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assets(", where, ") {",
            "  totalCount"
            "  items {"
            "    address"
            "    assetTokenId"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.assets.totalCount");

        assets = new AssetInfo[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assets[i].addr = json.readAddress(_buildJsonPath(".data.assets.items", i, "address"));
            assets[i].tokenId = json.readUint(_buildJsonPath(".data.assets.items", i, "assetTokenId"));
        }
    }

    function _bsManagers(PoolId poolId)
        internal
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "  isBalancesheetManager: true"
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "poolManagers(", where, ") {",
            "  totalCount"
            "  items {"
            "    address"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.poolManagers.totalCount");

        managers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            managers[i] = json.readAddress(_buildJsonPath(".data.poolManagers.items", i, "address"));
        }
    }

    function _hubManagers(PoolId poolId)
        internal
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "  isHubManager: true"
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "poolManagers(", where, ") {",
            "  totalCount"
            "  items {"
            "    address"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.poolManagers.totalCount");

        managers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            managers[i] = json.readAddress(_buildJsonPath(".data.poolManagers.items", i, "address"));
        }
    }

    function _onOfframpManagerV3(PoolId poolId)
        internal
        returns (OnOfframpManager manager)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "onOffRampManagers(", where, ") {",
            "  totalCount"
            "  items {"
            "    address"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.onOffRampManagers.totalCount");
        if (totalCount > 0) {
            // Only one item can exists per pool
            return OnOfframpManager(json.readAddress(".data.onOffRampManagers.items[0].address"));
        }
    }

    function _onOfframpReceivers(PoolId poolId)
        internal
        returns (address[] memory receivers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "offRampAddresss(", where, ") {",
            "  totalCount"
            "  items {"
            "    receiverAddress"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.offRampAddresss.totalCount");

        receivers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            receivers[i] = json.readAddress(_buildJsonPath(".data.offRampAddresss.items", i, "receiverAddress"));
        }
    }

    function _onOfframpRelayers(PoolId poolId)
        internal
        returns (address[] memory relayers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "offrampRelayers(", where, ") {",
            "  totalCount"
            "  items {"
            "    address"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.offrampRelayers.totalCount");

        relayers = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            relayers[i] = json.readAddress(_buildJsonPath(".data.offrampRelayers.items", i, "address"));
        }
    }

    function _chainsWherePoolIsNotified(PoolId poolId)
        internal
        returns (uint16[] memory centrifugeIds)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  id: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "pools(", where, ") {",
            "  totalCount"
            "  items {"
            "    spokeBlockchains {"
            "      totalCount"
            "      items {"
            "        centrifugeId"
            "      }"
            "    }"
            "  }"
            "}"
        ));

        if (json.readUint(".data.pools.totalCount") == 0) {
            return new uint16[](0);
        }

        uint256 totalCount = json.readUint(".data.pools.items[0].spokeBlockchains.totalCount");

        centrifugeIds = new uint16[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            centrifugeIds[i] =
                uint16(json.readUint(_buildJsonPath(".data.pools.items[0].spokeBlockchains.items", i, "centrifugeId")));
        }
    }
}

contract MigrationV3_1ExecutorMainnet is MigrationV3_1Executor {
    constructor() MigrationV3_1Executor(true) {}
}

contract MigrationV3_1ExecutorTestnet is MigrationV3_1Executor {
    constructor() MigrationV3_1Executor(false) {}
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {HubRegistry} from "../../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../../src/core/spoke/BalanceSheet.sol";
import {VaultRegistry} from "../../src/core/spoke/VaultRegistry.sol";
import {ContractUpdater} from "../../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../../src/core/hub/ShareClassManager.sol";
import {MessageDispatcher} from "../../src/core/messaging/MessageDispatcher.sol";

import {Root} from "../../src/admin/Root.sol";

import {FreezeOnly} from "../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../src/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../src/hooks/RedemptionRestrictions.sol";

import {OnOfframpManagerFactory, OnOfframpManager} from "../../src/managers/spoke/OnOfframpManager.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../src/vaults/BatchRequestManager.sol";

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {makeSalt} from "../CoreDeployer.s.sol";
import {CreateXScript} from "../utils/CreateXScript.sol";
import {GraphQLQuery} from "../utils/GraphQLQuery.s.sol";
import {
    PoolMigrationSpell,
    PoolParamsInput,
    OldContracts as PoolMigrationOldContracts
} from "../../src/spell/migration_v3.1/PoolMigrationSpell.sol";
import {
    GeneralMigrationSpell,
    GeneralParamsInput,
    OldContracts as GeneralMigrationOldContracts
} from "../../src/spell/migration_v3.1/GeneralMigrationSpell.sol";

contract MigrationV3_1 is Script, CreateXScript, GraphQLQuery {
    using stdJson for string;

    bytes32 constant NEW_VERSION = "3.1";
    Root public immutable root;
    uint16 public immutable centrifugeId;
    address deployer;

    constructor(address deployer_, uint16 centrifugeId_, bool isProduction) GraphQLQuery(isProduction) {
        centrifugeId = centrifugeId_;
        root = _root();
        deployer = deployer_;
    }

    receive() external payable {}

    function run(
        GeneralMigrationSpell generalMigrationSpell,
        PoolMigrationSpell poolMigrationSpell,
        PoolId[] memory poolsToMigrate
    ) external {
        vm.startBroadcast();

        migrate(generalMigrationSpell, poolMigrationSpell, poolsToMigrate);

        vm.stopBroadcast();
    }

    function migrate(
        GeneralMigrationSpell generalMigrationSpell,
        PoolMigrationSpell poolMigrationSpell,
        PoolId[] memory poolsToMigrate
    ) public {
        generalMigrationSpell.cast(
            GeneralParamsInput({
                v3: generalMigrationOldContracts(),
                root: root,
                spoke: Spoke(_contractAddr("spoke")),
                hubRegistry: HubRegistry(_contractAddr("hubRegistry")),
                messageDispatcher: MessageDispatcher(_contractAddr("messageDispatcher")),
                asyncRequestManager: AsyncRequestManager(payable(_contractAddr("asyncRequestManager"))),
                syncManager: SyncManager(_contractAddr("syncManager")),
                spokeAssetIds: _spokeAssetIds(),
                hubAssetIds: _hubAssetIds(),
                vaults: _vaults()
            })
        );

        for (uint256 i; i < poolsToMigrate.length; i++) {
            PoolId poolId = poolsToMigrate[i];
            poolMigrationSpell.castPool(
                poolId,
                PoolParamsInput({
                    v3: poolMigrationOldContracts(),
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

        poolMigrationSpell.lock();
    }

    function _contractAddr(string memory contractName) internal view returns (address) {
        return computeCreate3Address(makeSalt(contractName, NEW_VERSION, deployer), deployer);
    }

    function _root()
        internal
        returns (Root)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", where, ") {",
            "  items {"
            "      root"
            "  }"
            "}"
        ));

        return Root(json.readAddress(".data.deployments.items[0].root"));
    }

    function generalMigrationOldContracts()
        public
        returns (GeneralMigrationOldContracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", where, ") {",
            "  items {"
            "      gateway"
            "      spoke"
            "      hubRegistry"
            "      asyncRequestManager"
            "      syncManager"
            "  }"
            "}"
        ));

        v3.gateway = json.readAddress(".data.deployments.items[0].gateway");
        v3.spoke = json.readAddress(".data.deployments.items[0].spoke");
        v3.hubRegistry = json.readAddress(".data.deployments.items[0].hubRegistry");
        v3.asyncRequestManager = json.readAddress(".data.deployments.items[0].asyncRequestManager");
        v3.syncManager = json.readAddress(".data.deployments.items[0].syncManager");
    }

    function poolMigrationOldContracts()
        public
        returns (PoolMigrationOldContracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", where, ") {",
            "  items {"
            "      gateway"
            "      poolEscrowFactory"
            "      spoke"
            "      balanceSheet"
            "      hubRegistry"
            "      shareClassManager"
            "      asyncVaultFactory"
            "      asyncRequestManager"
            "      syncDepositVaultFactory"
            "      syncManager"
            "      freezeOnlyHook"
            "      fullRestrictionsHook", (isProduction) ?
            "      freelyTransferableHook" : "",
            "      redemptionRestrictionsHook"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
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
        returns (address[] memory assets)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "  }"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assets(", where, ") {",
            "  totalCount"
            "  items {"
            "    address"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.assets.totalCount");

        assets = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assets[i] = json.readAddress(_buildJsonPath(".data.assets.items", i, "address"));
        }
    }

    function _bsManagers(PoolId poolId)
        internal
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "      poolId: ", _jsonValue(poolId.raw()),
            "      isBalancesheetManager: true"
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "      poolId: ", _jsonValue(poolId.raw()),
            "      isHubManager: true"
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "      poolId: ", _jsonValue(poolId.raw()),
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "      poolId: ", _jsonValue(poolId.raw()),
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "      poolId: ", _jsonValue(poolId.raw()),
            "  }"
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
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId),
            "      id: ", _jsonValue(poolId.raw()),
            "  }"
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

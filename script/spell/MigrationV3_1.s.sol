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

Root constant ROOT_V3 = Root(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
address constant GATEWAY_V3 = 0x51eA340B3fe9059B48f935D5A80e127d587B6f89;
address constant POOL_ESCROW_FACTORRY_V3 = 0xD166B3210edBeEdEa73c7b2e8aB64BDd30c980E9;
address constant HUB_REGISTRY_V3 = 0x12044ef361Cc3446Cb7d36541C8411EE4e6f52cb;
address constant SHARE_CLASS_MANAGER_V3 = 0xe88e712d60bfd23048Dbc677FEb44E2145F2cDf4;
address constant BALANCE_SHEET_V3 = 0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda;
address constant SPOKE_V3 = 0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B;
address constant ASYNC_VAULT_FACTORY_V3 = 0xb47E57b4D477FF80c42dB8B02CB5cb1a74b5D20a;
address constant ASYNC_REQUEST_MANAGER_V3 = 0xf06f89A1b6C601235729A689595571B7455Dd433;
address constant SYNC_DEPOSIT_VAULT_FACTORY_V3 = 0x00E3c7EE9Bbc98B9Cb4Cc2c06fb211c1Bb199Ee5;
address constant SYNC_MANAGER_V3 = 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773;
address constant FREEZE_ONLY_HOOK_V3 = 0xBb7ABFB0E62dfb36e02CeeCDA59ADFD71f50c88e;
address constant FULL_RESTRICTIONS_HOOK_V3 = 0xa2C98F0F76Da0C97039688CA6280d082942d0b48;
address constant FREELY_TRANSFERABLE_HOOK_V3 = 0xbce8C1f411484C28a64f7A6e3fA63C56b6f3dDDE;
address constant REDEMPTION_RESTRICTIONS_HOOK_V3 = 0xf0C36EFD5F6465D18B9679ee1407a3FC9A2955dD;
address constant MESSAGE_DISPATCHER_V3 = 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132;

contract MigrationV3_1 is Script, CreateXScript {
    using stdJson for string;

    string constant GRAPHQL_API = "https://api.centrifuge.io/graphql";
    bytes32 constant VERSION = "3.1";
    uint16 public immutable centrifugeId;
    address deployer;

    constructor(address deployer_) {
        centrifugeId = MessageDispatcher(MESSAGE_DISPATCHER_V3).localCentrifugeId();
        deployer = deployer_;
    }

    receive() external payable {}

    function run(GeneralMigrationSpell generalMigrationSpell, PoolMigrationSpell poolMigrationSpell) external {
        vm.startBroadcast();

        migrate(generalMigrationSpell, poolMigrationSpell);

        vm.stopBroadcast();
    }

    function migrate(GeneralMigrationSpell generalMigrationSpell, PoolMigrationSpell poolMigrationSpell) public {
        generalMigrationSpell.cast(
            GeneralParamsInput({
                v3: GeneralMigrationOldContracts({
                    gateway: GATEWAY_V3,
                    spoke: SPOKE_V3,
                    hubRegistry: HUB_REGISTRY_V3,
                    asyncRequestManager: ASYNC_REQUEST_MANAGER_V3,
                    syncManager: SYNC_MANAGER_V3
                }),
                root: ROOT_V3,
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

        PoolId[] memory poolsToMigrate = _pools();
        for (uint256 i; i < poolsToMigrate.length; i++) {
            PoolId poolId = poolsToMigrate[i];
            poolMigrationSpell.castPool(
                poolId,
                PoolParamsInput({
                    v3: PoolMigrationOldContracts({
                        gateway: GATEWAY_V3,
                        poolEscrowFactory: POOL_ESCROW_FACTORRY_V3,
                        spoke: SPOKE_V3,
                        balanceSheet: BALANCE_SHEET_V3,
                        hubRegistry: HUB_REGISTRY_V3,
                        shareClassManager: SHARE_CLASS_MANAGER_V3,
                        asyncVaultFactory: ASYNC_VAULT_FACTORY_V3,
                        asyncRequestManager: ASYNC_REQUEST_MANAGER_V3,
                        syncDepositVaultFactory: SYNC_DEPOSIT_VAULT_FACTORY_V3,
                        syncManager: SYNC_MANAGER_V3,
                        freezeOnly: FREEZE_ONLY_HOOK_V3,
                        fullRestrictions: FULL_RESTRICTIONS_HOOK_V3,
                        freelyTransferable: FREELY_TRANSFERABLE_HOOK_V3,
                        redemptionRestrictions: REDEMPTION_RESTRICTIONS_HOOK_V3
                    }),
                    root: ROOT_V3,
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

    function _queryGraphQL(string memory query) internal returns (string memory json) {
        query = string.concat('{"query": "{', query, '}"}');
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] =
            string.concat("curl -s -X POST ", "-H 'Content-Type: application/json' ", "-d '", query, "' ", GRAPHQL_API);

        json = string(vm.ffi(cmd));

        if (json.keyExists(".errors[0].message")) {
            revert(json.readString(".errors[0].message"));
        }
    }

    function _buildJsonPath(string memory basePath, uint256 index, string memory fieldName)
        internal
        pure
        returns (string memory)
    {
        return string.concat(basePath, "[", vm.toString(index), "].", fieldName);
    }

    function _jsonValue(uint256 value) internal pure returns (string memory) {
        return string.concat("\\\"", vm.toString(value), "\\\"");
    }

    function _contractAddr(string memory contractName) internal view returns (address) {
        return computeCreate3Address(makeSalt(contractName, VERSION, deployer), deployer);
    }

    function _pools()
        internal
        returns (PoolId[] memory pools)
    {

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(
            "pools {"
            "  totalCount"
            "  items {"
            "    id"
            "  }"
            "}"
        );

        uint256 totalCount = json.readUint(".data.pools.totalCount");

        pools = new PoolId[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            pools[i] = PoolId.wrap(uint64(json.readUint(_buildJsonPath(".data.pools.items", i, "id"))));
        }
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

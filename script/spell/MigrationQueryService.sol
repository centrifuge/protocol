// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";

import {Root} from "../../src/admin/Root.sol";

import {OnOfframpManager} from "../../src/managers/spoke/OnOfframpManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {GraphQLQuery} from "../utils/GraphQLQuery.s.sol";
import {
    AssetInfo,
    PoolMigrationOldContracts,
    GlobalMigrationOldContracts
} from "../../src/spell/migration_v3.1/MigrationSpell.sol";

/// @title MigrationQueryService
/// @notice Centralized GraphQL query service for migration scripts
/// @dev Extracts query logic from MigrationV3_1Executor for reuse across spells and tests
contract MigrationQueryService is GraphQLQuery {
    using stdJson for string;

    string internal _api;
    uint16 internal _centrifugeId;
    bool internal _isMainnet;

    /// @param api_ GraphQL API endpoint (PRODUCTION_API or TESTNET_API)
    /// @param centrifugeId_ The centrifugeId to query for (from MessageDispatcher.localCentrifugeId())
    /// @param isMainnet_ True for mainnet, false for testnets (affects freelyTransferableHook handling)
    constructor(string memory api_, uint16 centrifugeId_, bool isMainnet_) {
        _api = api_;
        _centrifugeId = centrifugeId_;
        _isMainnet = isMainnet_;
    }

    function _graphQLApi() internal view override returns (string memory) {
        return _api;
    }

    // ============================================
    // Global Queries
    // ============================================

    /// @notice Get Root contract address from GraphQL
    function root()
        external
        returns (Root)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get v3.0.1 global contract addresses for migration
    function globalMigrationOldContracts()
        external
        returns (GlobalMigrationOldContracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get v3.0.1 pool-level contract addresses for migration
    /// @dev Public so tests can reuse this instead of duplicating addresses
    function poolMigrationOldContracts()
        external
        returns (PoolMigrationOldContracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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
            "    fullRestrictionsHook", (_isMainnet) ?
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
        if (_isMainnet) {
            v3.freelyTransferable = json.readAddress(".data.deployments.items[0].freelyTransferableHook");
        } else {
            v3.freelyTransferable = address(0xDEAD); // Not deployed in testnets
        }
        v3.redemptionRestrictions = json.readAddress(".data.deployments.items[0].redemptionRestrictionsHook");
    }

    /// @notice Get all spoke asset IDs for this chain
    function spokeAssetIds()
        external
        returns (AssetId[] memory assetIds)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get all hub asset IDs (registered assets) for this chain
    function hubAssetIds()
        external
        returns (AssetId[] memory assetIds)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get all vault addresses for this chain
    function vaults()
        external
        returns (address[] memory vaultAddrs)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

        vaultAddrs = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            vaultAddrs[i] = json.readAddress(_buildJsonPath(".data.vaults.items", i, "id"));
        }
    }

    /// @notice Get all asset info (address + tokenId) for this chain
    function assets()
        external
        returns (AssetInfo[] memory assetInfos)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

        assetInfos = new AssetInfo[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            assetInfos[i].addr = json.readAddress(_buildJsonPath(".data.assets.items", i, "address"));
            assetInfos[i].tokenId = json.readUint(_buildJsonPath(".data.assets.items", i, "assetTokenId"));
        }
    }

    // ============================================
    // Pool-Specific Queries
    // ============================================

    /// @notice Get balance sheet managers for a pool
    function bsManagers(PoolId poolId)
        external
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get hub managers for a pool
    function hubManagers(PoolId poolId)
        external
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get v3 OnOfframpManager for a pool (if exists)
    function onOfframpManagerV3(PoolId poolId)
        external
        returns (OnOfframpManager manager)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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
            // Only one item can exist per pool
            return OnOfframpManager(json.readAddress(".data.onOffRampManagers.items[0].address"));
        }
    }

    /// @notice Get offramp receiver addresses for a pool
    function onOfframpReceivers(PoolId poolId)
        external
        returns (address[] memory receivers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get offramp relayer addresses for a pool
    function onOfframpRelayers(PoolId poolId)
        external
        returns (address[] memory relayers)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    /// @notice Get chains where a pool has been notified (spoke blockchains)
    function chainsWherePoolIsNotified(PoolId poolId)
        external
        returns (uint16[] memory centrifugeIds)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(_centrifugeId),
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

    // ============================================
    // Utility Queries
    // ============================================

    /// @notice Get hub pools from all pools (pools where this chain is the hub)
    /// @param allPools All pools to filter
    /// @return result Pools where this chain is the hub
    function hubPools(PoolId[] memory allPools) external returns (PoolId[] memory result) {
        string memory json = _queryGraphQL(
            string.concat("pools(where: {centrifugeId: ", _jsonValue(_centrifugeId), "}) { items { id } totalCount }")
        );

        uint256 totalCount = json.readUint(".data.pools.totalCount");
        if (totalCount == 0) {
            return new PoolId[](0);
        }

        uint64[] memory hubIds = new uint64[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            hubIds[i] = uint64(json.readUint(_buildJsonPath(".data.pools.items", i, "id")));
        }

        result = new PoolId[](totalCount);
        uint256 count = 0;
        for (uint256 i = 0; i < allPools.length; i++) {
            uint64 poolIdRaw = PoolId.unwrap(allPools[i]);
            for (uint256 j = 0; j < hubIds.length; j++) {
                if (poolIdRaw == hubIds[j]) {
                    result[count++] = allPools[i];
                    break;
                }
            }
        }

        // Trim array to actual count
        assembly {
            mstore(result, count)
        }
    }

    // ============================================
    // Getters
    // ============================================

    /// @notice Get the stored centrifugeId
    function centrifugeId() external view returns (uint16) {
        return _centrifugeId;
    }

    /// @notice Check if configured for production
    function isMainnet() external view returns (bool) {
        return _isMainnet;
    }
}

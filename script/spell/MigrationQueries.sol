// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";

import {Root} from "../../src/admin/Root.sol";

import {OnOfframpManager} from "../../src/managers/spoke/OnOfframpManager.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {GraphQLQuery} from "../utils/GraphQLQuery.s.sol";
import {AssetInfo, V3Contracts} from "../../src/spell/migration_v3.1/MigrationSpell.sol";

struct VaultGraphQLData {
    address vault; // vaults.id
    uint64 poolIdRaw; // vaults.poolId
    bytes16 tokenIdRaw; // vaults.tokenId (scId as bytes16)
    string kind; // vaults.kind ("Async" | "SyncDepositAsyncRedeem")
    address assetAddress; // vaults.assetAddress
    uint8 assetDecimals; // vaults.asset.decimals
    string assetSymbol; // vaults.asset.symbol
    address hubManager; // vaults.token.pool.managers.items[0].address
    uint16 hubCentrifugeId; // vaults.token.pool.managers.items[0].centrifugeId
}

/// @title MigrationQueries
/// @notice Centralized GraphQL queries for migration scripts
/// @dev Extracts query logic from MigrationV3_1Executor for reuse across spells and tests
contract MigrationQueries is GraphQLQuery {
    using stdJson for string;

    string internal _api;
    uint16 public centrifugeId;
    bool public isMainnet;

    /// @param isMainnet_ True for mainnet, false for testnets (affects freelyTransferableHook handling)
    constructor(bool isMainnet_) {
        isMainnet = isMainnet_;
    }

    /// @param api_ GraphQL API endpoint (PRODUCTION_API or TESTNET_API)
    /// @param centrifugeId_ The centrifugeId to query for (from MessageDispatcher.localCentrifugeId())
    function configureGraphQl(string memory api_, uint16 centrifugeId_) public {
        _api = api_;
        centrifugeId = centrifugeId_;
    }

    function _graphQLApi() internal view override returns (string memory) {
        return _api;
    }

    // ============================================
    // Global Queries
    // ============================================

    /// @notice Get v3.0.1 pool-level contract addresses for migration
    /// @dev Public so tests can reuse this instead of duplicating addresses
    function v3Contracts()
        public
        returns (V3Contracts memory v3)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "deployments(", params, ") {",
            "  items {"
            "    root"
            "    guardian"
            "    tokenRecoverer"
            "    messageDispatcher"
            "    messageProcessor"
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
            "    fullRestrictionsHook", (isMainnet) ?
            "    freelyTransferableHook" : "",
            "    redemptionRestrictionsHook"
            "  }"
            "}"
        ));

        v3.root = Root(json.readAddress(".data.deployments.items[0].root"));
        v3.guardian = json.readAddress(".data.deployments.items[0].guardian");
        v3.tokenRecoverer = json.readAddress(".data.deployments.items[0].tokenRecoverer");
        v3.messageDispatcher = json.readAddress(".data.deployments.items[0].messageDispatcher");
        v3.messageProcessor = json.readAddress(".data.deployments.items[0].messageProcessor");
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
        if (isMainnet) {
            v3.freelyTransferable = json.readAddress(".data.deployments.items[0].freelyTransferableHook");
        } else {
            v3.freelyTransferable = address(0xDEAD); // Not deployed in testnets
        }
        v3.redemptionRestrictions = json.readAddress(".data.deployments.items[0].redemptionRestrictionsHook");
    }

    /// @notice Get all pools from all chains
    function pools()
        public
        returns (PoolId[] memory result)
    {

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "pools(limit: 1000) {",
            "  totalCount"
            "  items {"
            "    id"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.pools.totalCount");
        if (totalCount == 0) {
            return new PoolId[](0);
        }

        result = new PoolId[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            result[i] = PoolId.wrap(uint64(json.readUint(_buildJsonPath(".data.pools.items", i, "id"))));
        }
    }

    /// @notice Get all spoke asset IDs for this chain
    function spokeAssetIds()
        public
        returns (AssetId[] memory assetIds)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assets(", params, ") {",
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
        public
        returns (AssetId[] memory assetIds)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assetRegistrations(", params, ") {",
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
        public
        returns (address[] memory vaultAddrs)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "vaults(", params, ") {",
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
        public
        returns (AssetInfo[] memory assetInfos)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "assets(", params, ") {",
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
        public
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "  isBalancesheetManager: true"
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "poolManagers(", params, ") {",
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
        public
        returns (address[] memory managers)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "  isHubManager: true"
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "poolManagers(", params, ") {",
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
        public
        returns (OnOfframpManager manager)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "onOffRampManagers(", params, ") {",
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
        public
        returns (address[] memory receivers)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "offRampAddresss(", params, ") {",
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
        public
        returns (address[] memory relayers)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "offrampRelayers(", params, ") {",
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
        public
        returns (uint16[] memory centrifugeIds)
    {

        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  poolId: ", _jsonValue(poolId.raw()),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "poolSpokeBlockchains(", params, ") {",
            "  totalCount"
            "  items {"
            "    centrifugeId"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.poolSpokeBlockchains.totalCount");

        centrifugeIds = new uint16[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            centrifugeIds[i] =
                uint16(json.readUint(_buildJsonPath(".data.poolSpokeBlockchains.items", i, "centrifugeId")));
        }
    }

    // ============================================
    // Utility Queries
    // ============================================

    /// @notice Get hub pools from all pools (pools where this chain is the hub)
    /// @param allPools All pools to filter
    /// @return result Pools where this chain is the hub
    function hubPools(PoolId[] memory allPools) public returns (PoolId[] memory result) {
        string memory json = _queryGraphQL(
            string.concat("pools(where: {centrifugeId: ", _jsonValue(centrifugeId), "}) { items { id } totalCount }")
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

    /// @notice Get all vaults with linked status for the current chain
    /// @dev Used by investment validation to test vault flows
    function linkedVaults()
        external
        returns (address[] memory vaultAddrs)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "  where: {"
            "      centrifugeId: ", _jsonValue(centrifugeId), ","
            "      status: Linked"
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

        vaultAddrs = new address[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            vaultAddrs[i] = json.readAddress(_buildJsonPath(".data.vaults.items", i, "id"));
        }
    }

    /// @notice Get complete vault metadata for all linked vaults on this chain
    function linkedVaultsWithMetadata()
        external
        returns (VaultGraphQLData[] memory vaultData)
    {

        // forgefmt: disable-next-item
        string memory where = string.concat(
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId), ","
            "  status: Linked"
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "vaults(", where, ") {",
            "  totalCount"
            "  items {"
            "    id"
            "    poolId"
            "    tokenId"
            "    kind"
            "    assetAddress"
            "    asset {"
            "      decimals"
            "      symbol"
            "    }"
            "    token {"
            "      pool {"
            "        managers(where: {isHubManager: true}, limit: 1) {"
            "          items {"
            "            address"
            "            centrifugeId"
            "          }"
            "        }"
            "      }"
            "    }"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.vaults.totalCount");
        vaultData = new VaultGraphQLData[](totalCount);

        for (uint256 i = 0; i < totalCount; i++) {
            string memory base = _buildJsonPath(".data.vaults.items", i, "");

            vaultData[i].vault = json.readAddress(string.concat(base, "id"));
            vaultData[i].poolIdRaw = uint64(json.readUint(string.concat(base, "poolId")));
            vaultData[i].tokenIdRaw = _parseBytes16(json, string.concat(base, "tokenId"));
            vaultData[i].kind = json.readString(string.concat(base, "kind"));
            vaultData[i].assetAddress = json.readAddress(string.concat(base, "assetAddress"));
            vaultData[i].assetDecimals = uint8(json.readUint(string.concat(base, "asset.decimals")));
            vaultData[i].assetSymbol = json.readString(string.concat(base, "asset.symbol"));
            vaultData[i].hubManager = json.readAddress(string.concat(base, "token.pool.managers.items[0].address"));
            vaultData[i].hubCentrifugeId =
                uint16(json.readUint(string.concat(base, "token.pool.managers.items[0].centrifugeId")));
        }
    }

    function _parseBytes16(string memory json, string memory path) internal pure returns (bytes16 result) {
        bytes memory rawBytes = json.readBytes(path);
        require(rawBytes.length == 16, "Expected 16 bytes for tokenId");
        assembly {
            result := mload(add(rawBytes, 32))
        }
    }

    // ============================================
    // Getters
    // ============================================

    /// @notice Get the GraphQL API endpoint
    function graphQLApi() public view returns (string memory) {
        return _api;
    }
}

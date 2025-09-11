// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IShareClassManager, ShareClassMetadata, ShareClassMetrics} from "./interfaces/IShareClassManager.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {ShareClassId, newShareClassId} from "../common/types/ShareClassId.sol";

/// @title  Share Class Manager
/// @notice Manager for the share classes of a pool - handles share class creation, metadata, and share tracking
contract ShareClassManager is Auth, IShareClassManager {
    IHubRegistry public immutable hubRegistry;

    mapping(bytes32 salt => bool) public salts;
    mapping(PoolId poolId => uint32) public shareClassCount;
    mapping(ShareClassId scId => ShareClassMetrics) public metrics;
    mapping(ShareClassId scId => ShareClassMetadata) public metadata;
    mapping(PoolId poolId => mapping(ShareClassId => bool)) public shareClassIds;
    mapping(ShareClassId scId => mapping(uint16 centrifugeId => uint128)) public issuance;

    constructor(IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        auth
        returns (ShareClassId scId_)
    {
        scId_ = previewNextShareClassId(poolId);

        uint32 index = ++shareClassCount[poolId];
        shareClassIds[poolId][scId_] = true;

        _updateMetadata(scId_, name, symbol, salt);

        emit AddShareClass(poolId, scId_, index, name, symbol, salt);
    }

    /// @inheritdoc IShareClassManager
    function updateSharePrice(PoolId poolId, ShareClassId scId_, D18 navPoolPerShare) external auth {
        require(exists(poolId, scId_), ShareClassNotFound());

        ShareClassMetrics storage m = metrics[scId_];
        m.navPerShare = navPoolPerShare;
        emit UpdateShareClass(poolId, scId_, navPoolPerShare);
    }

    /// @inheritdoc IShareClassManager
    function updateMetadata(PoolId poolId, ShareClassId scId_, string calldata name, string calldata symbol)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        _updateMetadata(scId_, name, symbol, bytes32(0));

        emit UpdateMetadata(poolId, scId_, name, symbol);
    }

    /// @inheritdoc IShareClassManager
    function updateShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId_, uint128 amount, bool isIssuance)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        require(isIssuance || issuance[scId_][centrifugeId] >= amount, DecreaseMoreThanIssued());

        uint128 newTotalIssuance =
            isIssuance ? metrics[scId_].totalIssuance + amount : metrics[scId_].totalIssuance - amount;
        metrics[scId_].totalIssuance = newTotalIssuance;

        uint128 newIssuancePerNetwork =
            isIssuance ? issuance[scId_][centrifugeId] + amount : issuance[scId_][centrifugeId] - amount;
        issuance[scId_][centrifugeId] = newIssuancePerNetwork;

        if (isIssuance) emit RemoteIssueShares(centrifugeId, poolId, scId_, amount);
        else emit RemoteRevokeShares(centrifugeId, poolId, scId_, amount);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IShareClassManager
    function previewNextShareClassId(PoolId poolId) public view returns (ShareClassId scId) {
        return newShareClassId(poolId, shareClassCount[poolId] + 1);
    }

    /// @inheritdoc IShareClassManager
    function previewShareClassId(PoolId poolId, uint32 index) public pure returns (ShareClassId scId) {
        return newShareClassId(poolId, index);
    }

    /// @inheritdoc IShareClassManager
    function exists(PoolId poolId, ShareClassId scId_) public view returns (bool) {
        return shareClassIds[poolId][scId_];
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _updateMetadata(ShareClassId scId_, string calldata name, string calldata symbol, bytes32 salt) internal {
        uint256 nameLen = bytes(name).length;
        require(nameLen > 0 && nameLen <= 128, InvalidMetadataName());

        uint256 symbolLen = bytes(symbol).length;
        require(symbolLen > 0 && symbolLen <= 32, InvalidMetadataSymbol());

        ShareClassMetadata storage meta = metadata[scId_];

        // Ensure that the salt is not being updated or is being set for the first time
        require(
            (salt == bytes32(0) && meta.salt != bytes32(0)) || (salt != bytes32(0) && meta.salt == bytes32(0)),
            InvalidSalt()
        );

        if (salt != bytes32(0) && meta.salt == bytes32(0)) {
            require(!salts[salt], AlreadyUsedSalt());
            salts[salt] = true;
            meta.salt = salt;
        }

        meta.name = name;
        meta.symbol = symbol;
    }
}

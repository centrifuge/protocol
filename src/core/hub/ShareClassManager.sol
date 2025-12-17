// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IShareClassManager, ShareClassMetadata, Price, IssuancePerNetwork} from "./interfaces/IShareClassManager.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId, newShareClassId} from "../types/ShareClassId.sol";

/// @title  Share Class Manager
/// @notice Manager for the share classes of a pool - handles share class creation, metadata, and share tracking
contract ShareClassManager is Auth, IShareClassManager {
    IHubRegistry public immutable hubRegistry;

    mapping(bytes32 salt => bool) public salts;
    mapping(PoolId => uint32) public shareClassCount;
    mapping(PoolId => mapping(ShareClassId => bool)) public shareClassIds;
    mapping(PoolId => mapping(ShareClassId => uint128)) public totalIssuance;
    mapping(PoolId => mapping(ShareClassId => Price)) public pricePoolPerShare;
    mapping(PoolId => mapping(ShareClassId => ShareClassMetadata)) public metadata;
    mapping(PoolId => mapping(ShareClassId => mapping(uint16 centrifugeId => IssuancePerNetwork))) public
        issuancePerNetwork;

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
        PoolId prefixedPoolId = PoolId.wrap(uint64(bytes8(salt)));
        require(poolId == prefixedPoolId, InvalidSalt());
        require(!salts[salt], AlreadyUsedSalt());

        scId_ = previewNextShareClassId(poolId);

        uint32 index = ++shareClassCount[poolId];
        shareClassIds[poolId][scId_] = true;

        ShareClassMetadata storage meta = _updateMetadata(poolId, scId_, name, symbol);

        salts[salt] = true;
        meta.salt = salt;

        emit AddShareClass(poolId, scId_, index, name, symbol, salt);
    }

    /// @inheritdoc IShareClassManager
    function updateSharePrice(PoolId poolId, ShareClassId scId_, D18 pricePoolPerShare_, uint64 computedAt)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());
        Price storage p = pricePoolPerShare[poolId][scId_];
        require(computedAt <= block.timestamp, CannotSetFuturePrice());

        p.price = pricePoolPerShare_;
        p.computedAt = computedAt;
        emit UpdatePricePoolPerShare(poolId, scId_, pricePoolPerShare_, computedAt);
    }

    /// @inheritdoc IShareClassManager
    function updateMetadata(PoolId poolId, ShareClassId scId_, string calldata name, string calldata symbol)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        _updateMetadata(poolId, scId_, name, symbol);

        emit UpdateMetadata(poolId, scId_, name, symbol);
    }

    /// @inheritdoc IShareClassManager
    function updateShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId_, uint128 amount, bool isIssuance)
        external
        auth
    {
        require(exists(poolId, scId_), ShareClassNotFound());

        IssuancePerNetwork storage ipn = issuancePerNetwork[poolId][scId_][centrifugeId];

        if (isIssuance) {
            ipn.issuances += amount;
            totalIssuance[poolId][scId_] += amount;
        } else {
            ipn.revocations += amount;
            totalIssuance[poolId][scId_] -= amount;
        }

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

    /// @inheritdoc IShareClassManager
    function issuance(PoolId poolId, ShareClassId scId_, uint16 centrifugeId) public view returns (uint128) {
        IssuancePerNetwork storage ipn = issuancePerNetwork[poolId][scId_][centrifugeId];
        require(ipn.issuances >= ipn.revocations, NegativeIssuance());
        return ipn.issuances - ipn.revocations;
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _updateMetadata(PoolId poolId, ShareClassId scId_, string calldata name, string calldata symbol)
        internal
        returns (ShareClassMetadata storage meta)
    {
        uint256 nameLen = bytes(name).length;
        require(nameLen > 0 && nameLen <= 128, InvalidMetadataName());

        uint256 symbolLen = bytes(symbol).length;
        require(symbolLen > 0 && symbolLen <= 32, InvalidMetadataSymbol());

        meta = metadata[poolId][scId_];
        meta.name = name;
        meta.symbol = symbol;
    }
}

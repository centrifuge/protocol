// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

struct ShareClassMetadata {
    /// @dev The name of the share class token
    string name;
    /// @dev The symbol of the share class token
    string symbol;
    /// @dev The salt of the share class token
    bytes32 salt;
}

struct ShareClassMetrics {
    /// @dev Total number of shares
    uint128 totalIssuance;
    /// @dev The latest net asset value per share class token
    D18 navPerShare;
}

interface IShareClassManager {
    /// Events
    event AddShareClass(
        PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index, string name, string symbol, bytes32 salt
    );
    event UpdateMetadata(PoolId indexed poolId, ShareClassId indexed scId, string name, string symbol);
    event UpdateShareClass(PoolId indexed poolId, ShareClassId indexed scId, D18 navPoolPerShare);
    event RemoteIssueShares(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId indexed scId, uint128 amount
    );
    event RemoteRevokeShares(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId indexed scId, uint128 amount
    );

    /// Errors
    error InvalidMetadataSize();
    error InvalidMetadataName();
    error InvalidMetadataSymbol();
    error InvalidSalt();
    error AlreadyUsedSalt();
    error PoolMissing();
    error ShareClassNotFound();

    /// Functions

    /// @notice Update the share class issuance
    ///
    /// @param centrifugeId Identifier of the chain
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount The amount to increase the share class issuance by
    /// @param isIssuance Whether it is an issuance or revocation
    function updateShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint128 amount, bool isIssuance)
        external;

    /// @notice Adds a new share class to the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    /// @param salt The salt used for deploying the share class tokens
    /// @return scId Identifier of the newly added share class
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId);

    /// @notice Updates the price pool unit per share unit of a share class
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param pricePoolPerShare The price per share of the share class (in the pool currency denomination)
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external;

    /// @notice Updates the metadata of a share class.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    function updateMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol) external;

    /// @notice Returns the number of share classes for the given pool
    ///
    /// @param poolId Identifier of the pool in question
    /// @return count Number of share classes for the given pool
    function shareClassCount(PoolId poolId) external view returns (uint32 count);

    /// @notice Checks the existence of a share class.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    function exists(PoolId poolId, ShareClassId scId) external view returns (bool);

    /// @notice Exposes relevant metrics for a share class
    ///
    /// @return totalIssuance The total number of shares known to the Hub side
    /// @return pricePoolPerShare The amount of pool units per unit share
    function metrics(ShareClassId scId) external view returns (uint128 totalIssuance, D18 pricePoolPerShare);

    /// @notice Exposes issuance of a share class on a given network
    ///
    /// @param scId Identifier of the share class
    /// @param centrifugeId Identifier of the chain
    function issuance(ShareClassId scId, uint16 centrifugeId) external view returns (uint128);

    /// @notice Determines the next share class id for the given pool.
    ///
    /// @param poolId Identifier of the pool
    /// @return scId Identifier of the next share class
    function previewNextShareClassId(PoolId poolId) external view returns (ShareClassId scId);

    /// @notice Determines the share class id for the given pool and index.
    ///
    /// @param poolId Identifier of the pool
    /// @param index The pool-internal index of the share class id
    /// @return scId Identifier of the underlying share class
    function previewShareClassId(PoolId poolId, uint32 index) external pure returns (ShareClassId scId);

    /// @notice returns The metadata of the share class.
    ///
    /// @param scId Identifier of the share class
    /// @return name The registered name of the share class token
    /// @return symbol The registered symbol of the share class token
    /// @return salt The registered salt of the share class token, used for deterministic deployments
    function metadata(ShareClassId scId)
        external
        view
        returns (string memory name, string memory symbol, bytes32 salt);
}

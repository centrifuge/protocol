// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

struct ShareClassMetadata {
    /// @dev The name of the share class token
    string name;
    /// @dev The symbol of the share class token
    string symbol;
    /// @dev The salt of the share class token
    bytes32 salt;
}

struct Price {
    /// @dev The latest price per share class token
    D18 price;
    /// @dev Timestamp when the price pool per share was computed
    uint64 computedAt;
}

interface IShareClassManager {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event AddShareClass(
        PoolId indexed poolId, ShareClassId indexed scId, uint32 indexed index, string name, string symbol, bytes32 salt
    );
    event UpdateMetadata(PoolId indexed poolId, ShareClassId indexed scId, string name, string symbol);
    event UpdatePricePoolPerShare(PoolId indexed poolId, ShareClassId indexed scId, D18 price, uint64 computedAt);
    event RemoteIssueShares(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId indexed scId, uint128 amount
    );
    event RemoteRevokeShares(
        uint16 indexed centrifugeId, PoolId indexed poolId, ShareClassId indexed scId, uint128 amount
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidMetadataSize();
    error InvalidMetadataName();
    error InvalidMetadataSymbol();
    error InvalidSalt();
    error AlreadyUsedSalt();
    error PoolMissing();
    error ShareClassNotFound();
    error DecreaseMoreThanIssued();
    error CannotSetFuturePrice();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Update the share class issuance
    /// @param centrifugeId Identifier of the chain
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param amount The amount to increase or decrease the share class issuance by
    /// @param isIssuance Whether it is an issuance or revocation
    function updateShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint128 amount, bool isIssuance)
        external;

    /// @notice Adds a new share class to the given pool
    /// @param poolId Identifier of the pool
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    /// @param salt The salt used for deploying the share class tokens
    /// @return scId Identifier of the newly added share class
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId);

    /// @notice Updates the price pool unit per share unit of a share class
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param pricePoolPerShare The price per share of the share class (in the pool currency denomination)
    /// @param computedAt Timestamp when the price was computed (must be <= block.timestamp)
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt) external;

    /// @notice Updates the metadata of a share class
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param name The name of the share class
    /// @param symbol The symbol of the share class
    function updateMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the number of share classes for the given pool
    /// @param poolId Identifier of the pool in question
    /// @return count Number of share classes for the given pool
    function shareClassCount(PoolId poolId) external view returns (uint32 count);

    /// @notice Checks the existence of a share class
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return Whether the share class exists
    function exists(PoolId poolId, ShareClassId scId) external view returns (bool);

    /// @notice Returns the current price per share and when it was computed
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return price The latest price per share (in pool currency denomination)
    /// @return computedAt Timestamp when the price was computed (may be earlier than submission time)
    function pricePoolPerShare(PoolId poolId, ShareClassId scId) external view returns (D18 price, uint64 computedAt);

    /// @notice Returns the total issuance across all networks for a share class
    /// @dev     This is only updated when queued shares on the spoke are updated to the hub, so can
    ///                maybe out of sync and not reflect the exact latest issuance across networks.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return totalIssuance The total number of shares known to the Hub side
    function totalIssuance(PoolId poolId, ShareClassId scId) external view returns (uint128 totalIssuance);

    /// @notice Exposes issuance of a share class on a given network
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param centrifugeId Identifier of the chain
    /// @return The share issuance on the specified network
    function issuance(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external view returns (uint128);

    /// @notice Determines the next share class id for the given pool
    /// @param poolId Identifier of the pool
    /// @return scId Identifier of the next share class
    function previewNextShareClassId(PoolId poolId) external view returns (ShareClassId scId);

    /// @notice Determines the share class id for the given pool and index
    /// @param poolId Identifier of the pool
    /// @param index The pool-internal index of the share class id
    /// @return scId Identifier of the underlying share class
    function previewShareClassId(PoolId poolId, uint32 index) external pure returns (ShareClassId scId);

    /// @notice Returns the metadata of the share class
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return name The registered name of the share class token
    /// @return symbol The registered symbol of the share class token
    /// @return salt The registered salt of the share class token, used for deterministic deployments
    function metadata(PoolId poolId, ShareClassId scId)
        external
        view
        returns (string memory name, string memory symbol, bytes32 salt);
}

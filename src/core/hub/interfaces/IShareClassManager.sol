// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IHubRegistry} from "./IHubRegistry.sol";

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

struct IssuanceCounters {
    /// @dev Total accumulated amount of shares issued
    uint128 issuances;
    /// @dev Total accumulated amount of shares revoked
    uint128 revocations;
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

    /// @notice Emitted when the number of networks that have revoked more than they reported issuing changes
    event UpdateNegativeNetworkCount(
        PoolId indexed poolId, ShareClassId indexed scId, uint16 indexed centrifugeId, uint32 count
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidMetadataName();
    error InvalidMetadataSymbol();
    error InvalidSalt();
    error AlreadyUsedSalt();
    error ShareClassNotFound();
    error NegativeIssuance();
    error CannotSetFuturePrice();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Update the share class issuance
    /// @dev    Both counters only ever go up, so a revocation bigger than everything issued so far does not
    ///         revert. The extra is simply added to `revocations` and cancels out against later issuances.
    ///         This happens in normal operation: when shares are bridged off a chain, the hub subtracts them
    ///         from that chain right away, but the issuance that minted them may still be sitting in the
    ///         chain's queue. If this reverted, the sending chain's snapshot nonce would never be consumed
    ///         and every later message from it would be rejected.
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
    ///                Reverts with {NegativeIssuance} if any chain has revoked more than it has reported
    ///                issuing, since the total would be wrong. Read {issuanceAcrossNetworks} for the two
    ///                counters it is derived from, which are always readable.
    ///
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return totalIssuance The total number of shares known to the Hub side
    function totalIssuance(PoolId poolId, ShareClassId scId) external view returns (uint128 totalIssuance);

    /// @notice Exposes issuance of a share class on a given network
    /// @dev    Reverts with {NegativeIssuance} if the chain has revoked more than it has reported issuing,
    ///         since the figure would be wrong. Anything called while handling an incoming message should
    ///         read {issuancePerNetwork} and deal with the difference itself, because a revert would undo
    ///         that message and leave the chain unable to report anything further.
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param centrifugeId Identifier of the chain
    /// @return The share issuance on the specified network
    function issuance(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external view returns (uint128);

    /// @notice Returns the number of networks that have revoked more shares than they have reported issuing
    /// @dev    Non-zero means the netted total is smaller than the shares the networks really hold, by exactly
    ///         the sum of those networks' shortfalls - so anything derived from the total, a price per share
    ///         above all, would be wrong. Shares bridged off a network before it submits the issuance that
    ///         minted them is what puts one in this state, and its own submission is what clears it.
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return count The number of networks in that state
    function negativeNetworkCount(PoolId poolId, ShareClassId scId) external view returns (uint32 count);

    /// @notice Returns the combined issuance (issuances and revocations) for a share class across all networks
    /// @dev    Always readable, unlike {totalIssuance}. If `revocations` is larger than `issuances`, at
    ///         least one chain has bridged shares away before reporting that it issued them, and the
    ///         difference is how many shares the hub has not been told about yet.
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @return issuances The cumulative amount ever issued across all networks
    /// @return revocations The cumulative amount ever revoked across all networks
    function issuanceAcrossNetworks(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 issuances, uint128 revocations);

    /// @notice Returns the combined issuance (issuances and revocations) for a share class on a given network
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    /// @param centrifugeId Identifier of the chain
    /// @return issuances The total accumulated amount of shares issued on this network
    /// @return revocations The total accumulated amount of shares revoked on this network
    function issuancePerNetwork(PoolId poolId, ShareClassId scId, uint16 centrifugeId)
        external
        view
        returns (uint128 issuances, uint128 revocations);

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

    /// @notice Registry of pools, assets, and manager permissions on the hub chain
    function hubRegistry() external view returns (IHubRegistry);

    /// @notice Whether a CREATE3 deployment salt has already been consumed
    /// @param salt The salt to check
    function salts(bytes32 salt) external view returns (bool);

    /// @notice Whether a share class ID has been registered for a pool
    /// @param poolId Identifier of the pool
    /// @param scId Identifier of the share class
    function shareClassIds(PoolId poolId, ShareClassId scId) external view returns (bool);
}

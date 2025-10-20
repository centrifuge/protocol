// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IShareToken} from "./IShareToken.sol";
import {IVault, VaultKind} from "./IVault.sol";

import {D18} from "../../../misc/types/D18.sol";

import {Price} from "../types/Price.sol";
import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IRequestManager} from "../../interfaces/IRequestManager.sol";
import {IVaultFactory} from "../factories/interfaces/IVaultFactory.sol";

/// @dev Centrifuge pools
struct Pool {
    /// @dev Timestamp of pool creation
    uint64 createdAt;
}

/// @dev Each Centrifuge pool is associated to 1 or more share classes
struct ShareClassDetails {
    IShareToken shareToken;
    /// @dev Each share class has an individual price per share class unit in pool denomination (POOL_UNIT/SHARE_UNIT)
    Price pricePoolPerShare;
}

struct AssetIdKey {
    /// @dev The address of the asset
    address asset;
    /// @dev The ERC6909 token id or 0, if the underlying asset is an ERC20
    uint256 tokenId;
}

interface ISpoke {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event RegisterAsset(
        uint16 centrifugeId,
        AssetId indexed assetId,
        address indexed asset,
        uint256 indexed tokenId,
        string name,
        string symbol,
        uint8 decimals,
        bool isInitialization
    );
    event AddPool(PoolId indexed poolId);
    event AddShareClass(PoolId indexed poolId, ShareClassId indexed scId, IShareToken token);
    event DeployVault(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault,
        VaultKind kind
    );
    event SetRequestManager(PoolId indexed poolId, IRequestManager manager);
    event UpdateAssetPrice(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        uint256 tokenId,
        D18 price,
        uint64 computedAt
    );
    event UpdateSharePrice(PoolId indexed poolId, ShareClassId indexed scId, D18 price, uint64 computedAt);
    event InitiateTransferShares(
        uint16 centrifugeId,
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed sender,
        bytes32 destinationAddress,
        uint128 amount
    );
    event ExecuteTransferShares(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed receiver, uint128 amount
    );
    event LinkVault(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed asset, uint256 tokenId, IVault vault
    );
    event UnlinkVault(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed asset, uint256 tokenId, IVault vault
    );
    event UpdateMaxSharePriceAge(PoolId indexed poolId, ShareClassId indexed scId, uint64 maxPriceAge);
    event UpdateMaxAssetPriceAge(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed asset, uint256 tokenId, uint64 maxPriceAge
    );
    event UntrustedContractUpdate(
        uint16 indexed centrifugeId,
        PoolId indexed poolId,
        ShareClassId scId,
        bytes32 target,
        bytes payload,
        address indexed sender
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error TooFewDecimals();
    error TooManyDecimals();
    error PoolAlreadyAdded();
    error InvalidPool();
    error ShareClassAlreadyRegistered();
    error InvalidHook();
    error OldMetadata();
    error CannotSetOlderPrice();
    error OldHook();
    error UnknownVault();
    error UnknownAsset();
    error MalformedVaultUpdateMessage();
    error InvalidFactory();
    error InvalidPrice();
    error AssetMissingDecimals();
    error ShareTokenDoesNotExist();
    error LocalTransferNotAllowed();
    error CrossChainTransferNotAllowed();
    error ShareTokenTransferFailed();
    error TransferFromFailed();
    error InvalidRequestManager();
    error RequestManagerNotSet();
    error InvalidManager();
    error InvalidVault();
    error AlreadyLinkedVault();
    error AlreadyUnlinkedVault();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'gateway', 'investmentManager', 'tokenFactory', or 'gasService'
    /// @param data The new address
    function file(bytes32 what, address data) external;

    /// @notice Links a share token to a pool and share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shareToken The share token contract
    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken) external;

    /// @notice Updates a share token's vault reference for a specific asset
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param asset The asset address
    /// @param vault The vault address to set (or address(0) to unset)
    function setShareTokenVault(PoolId poolId, ShareClassId scId, address asset, address vault) external;

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @notice Transfers share class tokens to a cross-chain recipient address
    /// @dev To transfer to evm chains, pad a 20 byte evm address with 12 bytes of 0
    /// @param centrifugeId The destination chain id
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param receiver A bytes32 representation of the receiver address
    /// @param amount The amount of tokens to transfer
    /// @param extraGasLimit Extra gas limit used for computation on the intermediary hub
    /// @param remoteExtraGasLimit Extra gas limit used for computation in the destination chain
    /// @param refund Address to refund the excess of the payment
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable;

    /// @notice Transfers share class tokens to a cross-chain recipient address (legacy)
    /// @dev Maintained for retrocompatibility. New implementers should use the above
    /// @param centrifugeId The centrifuge id of chain to where the shares are transferred
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param receiver A bytes32 representation of the receiver address
    /// @param amount The amount of tokens to transfer
    /// @param remoteExtraGasLimit Extra gas limit used for computation in the destination chain
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable;

    /// @notice Registers an ERC-20 or ERC-6909 asset in another chain.
    /// @dev `decimals()` MUST return a `uint8` value between 2 and 18.
    /// @dev `name()` and `symbol()` MAY return no values.
    ///
    /// @param centrifugeId The centrifuge id of chain to where the shares are transferred
    /// @param asset The address of the asset to be registered
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @param refund Address to refund the excess of the payment
    /// @return assetId The underlying internal uint128 assetId.
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId, address refund)
        external
        payable
        returns (AssetId assetId);

    /// @notice Initiates an update to a hub-side contract from spoke
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param target The hub-side target contract (as bytes32 for cross-chain compatibility)
    /// @param payload The update payload
    /// @param extraGasLimit Additional gas for cross-chain execution
    /// @param refund Address to refund excess payment
    /// @dev Permissionless by choice, forwards caller's address to recipient for permission validation
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Handles a request originating from the Spoke side
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param payload The request payload to be processed
    /// @param refund Address to refund excess payment
    /// @param unpaid Whether to allow unpaid mode
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        address refund,
        bool unpaid
    ) external payable;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the asset address and tokenId associated with a given asset id.
    /// @dev Reverts if asset id does not exist
    ///
    /// @param assetId The underlying internal uint128 assetId.
    /// @return asset The address of the asset linked to the given asset id.
    /// @return tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    function idToAsset(AssetId assetId) external view returns (address asset, uint256 tokenId);

    /// @notice Returns assetId given the asset address and tokenId.
    /// @dev Reverts if asset id does not exist
    ///
    /// @param asset The address of the asset linked to the given asset id.
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @return assetId The underlying internal uint128 assetId.
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId);

    /// @notice Returns whether the given pool id is active
    /// @param poolId The pool id
    /// @return Whether the pool is active
    function isPoolActive(PoolId poolId) external view returns (bool);

    /// @notice Returns the share class token for a given pool and share class id
    /// @dev Reverts if share class does not exists
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return The address of the share token
    function shareToken(PoolId poolId, ShareClassId scId) external view returns (IShareToken);

    /// @notice Returns the price per share for a given pool and share class
    /// @dev The provided price is defined as POOL_UNIT/SHARE_UNIT
    /// @dev Conditionally checks if price is valid
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param checkValidity Whether to check if the price is valid
    /// @return price The pool price per share
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) external view returns (D18 price);

    /// @notice Returns the price per asset for a given pool, share class and the underlying asset id
    /// @dev The provided price is defined as POOL_UNIT/ASSET_UNIT
    /// @dev Conditionally checks if price is valid
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to know the POOL_UNIT/ASSET_UNIT
    /// @param checkValidity Whether to check if the price is valid
    /// @return price The pool price per asset unit
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 price);

    /// @notice Returns both prices per pool for a given pool, share class and the underlying asset id
    /// @dev The provided prices are defined as POOL_UNIT/ASSET_UNIT and POOL_UNIT/SHARE_UNIT
    /// @dev Conditionally checks if prices are valid
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to know pool price per asset
    /// @param checkValidity Whether to check if the prices are valid
    /// @return pricePoolPerAsset The pool price per asset unit, i.e. POOL_UNIT/ASSET_UNIT
    /// @return pricePoolPerShare The pool price per share unit, i.e. POOL_UNIT/SHARE_UNIT
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 pricePoolPerAsset, D18 pricePoolPerShare);

    /// @notice Returns the age related markers for a share class price
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return computedAt The timestamp when this price was computed
    /// @return maxAge The maximum age this price is allowed to have
    /// @return validUntil The timestamp until this price is valid
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice Returns the age related markers for an asset price
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to know pool price per asset
    /// @return computedAt The timestamp when this price was computed
    /// @return maxAge The maximum age this price is allowed to have
    /// @return validUntil The timestamp until this price is valid
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice Returns the request manager for a given pool
    /// @param poolId The pool id
    /// @return manager The request manager for the pool
    function requestManager(PoolId poolId) external view returns (IRequestManager manager);
}

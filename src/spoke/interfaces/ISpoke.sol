// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {Price} from "src/spoke/types/Price.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IVault, VaultKind} from "src/spoke/interfaces/IVault.sol";
import {IRequestManager} from "src/spoke/interfaces/IRequestManager.sol";
import {IVaultFactory} from "src/spoke/factories/interfaces/IVaultFactory.sol";

/// @dev Centrifuge pools
struct Pool {
    uint256 createdAt;
    mapping(ShareClassId scId => ShareClassDetails) shareClasses;
}

struct ShareClassAsset {
    /// @dev Manager that can send requests, and handles the request callbacks.
    IRequestManager manager;
    /// @dev Number of linked vaults.
    uint32 numVaults;
}

/// @dev Each Centrifuge pool is associated to 1 or more shar classes
struct ShareClassDetails {
    IShareToken shareToken;
    /// @dev Each share class has an individual price per share class unit in pool denomination (POOL_UNIT/SHARE_UNIT)
    Price pricePoolPerShare;
    mapping(AssetId assetId => ShareClassAsset) asset;
    /// @dev For each share class, we store the price per pool unit in asset denomination (POOL_UNIT/ASSET_UNIT)
    mapping(address asset => mapping(uint256 tokenId => Price)) pricePoolPerAsset;
}

struct VaultDetails {
    /// @dev AssetId of the asset
    AssetId assetId;
    /// @dev Address of the asset
    address asset;
    /// @dev TokenId of the asset - zero if asset is ERC20, non-zero if asset is ERC6909
    uint256 tokenId;
    /// @dev Whether the vault is linked to a share class atm
    bool isLinked;
}

struct AssetIdKey {
    /// @dev The address of the asset
    address asset;
    /// @dev The ERC6909 token id or 0, if the underlying asset is an ERC20
    uint256 tokenId;
}

interface ISpoke {
    event File(bytes32 indexed what, address data);
    event RegisterAsset(
        AssetId indexed assetId,
        address indexed asset,
        uint256 indexed tokenId,
        string name,
        string symbol,
        uint8 decimals,
        bool isInitialization
    );
    event File(bytes32 indexed what, address factory, bool status);
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
    event SetRequestManager(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, IRequestManager manager
    );
    event UpdateAssetPrice(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        uint256 tokenId,
        uint256 price,
        uint64 computedAt
    );
    event UpdateSharePrice(PoolId indexed poolId, ShareClassId indexed scId, uint256 price, uint64 computedAt);
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
    error UnknownToken();
    error InvalidFactory();
    error InvalidPrice();
    error AssetMissingDecimals();
    error ShareTokenDoesNotExist();
    error LocalTransferNotAllowed();
    error CrossChainTransferNotAllowed();
    error ShareTokenTransferFailed();
    error TransferFromFailed();
    error InvalidRequestManager();
    error MoreThanZeroLinkedVaults();
    error RequestManagerNotSet();
    error InvalidManager();
    error InvalidVault();

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

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'gateway', 'requestManager', 'tokenFactory',
    ///                or 'gasService'
    function file(bytes32 what, address data) external;

    /// @notice transfers share class tokens to a cross-chain recipient address
    /// @dev    To transfer to evm chains, pad a 20 byte evm address with 12 bytes of 0
    /// @param  centrifugeId The destination chain id
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  receiver A bytes32 representation of the receiver address
    /// @param  amount The amount of tokens to transfer
    /// @param  remoteExtraGasLimit extra gas limit used for some extra computation that could happen in the chain where
    /// the transfer is executed.
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
    /// @return assetId The underlying internal uint128 assetId.
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId)
        external
        payable
        returns (AssetId assetId);

    function linkToken(PoolId poolId, ShareClassId scId, IShareToken shareToken) external;

    /// @notice Handles a request originating from the Spoke side.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The request payload to be processed
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external;

    /// @notice Deploys a new vault
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param factory The address of the corresponding vault factory
    /// @return address The address of the deployed vault
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        external
        returns (IVault);

    /// @notice Register a vault.
    function registerVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault
    ) external;

    /// @notice Links a deployed vault to the given pool, share class and asset.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param vault The address of the deployed vault
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Removes the link between a vault and the given pool, share class and asset.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to deploy a vault
    /// @param vault The address of the deployed vault
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault) external;

    /// @notice Returns whether the given pool id is active
    function isPoolActive(PoolId poolId) external view returns (bool);

    /// @notice Returns the share class token for a given pool and share class id.
    /// @dev Reverts if share class does not exists
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return address The address of the share token
    function shareToken(PoolId poolId, ShareClassId scId) external view returns (IShareToken);

    /// @notice Function to get the details of a vault
    /// @dev    Reverts if vault does not exist
    ///
    /// @param vault The address of the vault to be checked for
    /// @return details The details of the vault including the underlying asset address, token id, asset id
    function vaultDetails(IVault vault) external view returns (VaultDetails memory details);

    /// @notice Checks whether a given vault is eligible for investing into a share class of a pool
    ///
    /// @param vault The address of the vault
    /// @return bool Whether vault is to a share class
    function isLinked(IVault vault) external view returns (bool);

    /// @notice Returns the price per share for a given pool and share class. The Provided price is defined as
    /// POOL_UNIT/SHARE_UNIT.
    /// @dev Conditionally checks if price is valid.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param checkValidity Whether to check if the price is valid
    /// @return price The pool price per share
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity)
        external
        view
        returns (D18 price);

    /// @notice Returns the price per asset for a given pool, share class and the underlying asset id. The Provided
    /// price is defined as POOL_UNIT/ASSET_UNIT.
    /// @dev Conditionally checks if price is valid.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to know the POOL_UNIT/ASSET_UNIT.
    /// @param checkValidity Whether to check if the price is valid
    /// @return price The pool price per asset unit
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 price);

    /// @notice Returns the both prices per pool for a given pool, share class and the underlying asset id. The Provided
    /// prices is defined as POOL_UNIT/ASSET_UNIT and POOL_UNIT/SHARE_UNIT.
    /// @dev Conditionally checks if prices are valid.
    ///
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
    ///
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
    ///
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
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRecoverable} from "src/common/interfaces/IRoot.sol";

/// @dev Centrifuge pools
struct Pool {
    uint256 createdAt;
    mapping(bytes16 trancheId => TrancheDetails) tranches;
}

/// @dev Each Centrifuge pool is associated to 1 or more tranches
struct TrancheDetails {
    address token;
    /// @dev Each tranche can have multiple vaults deployed,
    ///      multiple vaults can be linked to the same asset.
    ///      A vault in this storage DOES NOT mean the vault can be used
    mapping(address asset => mapping(uint256 tokenId => address[])) vaults;
    /// @dev Each tranche has a price per asset
    mapping(address asset => mapping(uint256 tokenId => TranchePrice)) prices;
}

struct TranchePrice {
    uint128 price;
    uint64 computedAt;
}

/// @dev Temporary storage that is only present between addTranche and deployTranche
struct UndeployedTranche {
    /// @dev The decimals of the leading pool asset. Vault shares have
    ///      to be denomatimated with the same precision.
    uint8 decimals;
    /// @dev Metadata of the to be deployed erc20 token
    string tokenName;
    string tokenSymbol;
    bytes32 salt;
    /// @dev Address of the hook
    address hook;
}

struct VaultDetails {
    /// @dev AssetId of the asset
    uint128 assetId;
    /// @dev Address of the asset
    address asset;
    /// @dev TokenId of the asset - zero if asset is ERC20, non-zero if asset is ERC6909
    uint256 tokenId;
    /// @dev Whether this wrapper conforms to the IERC20Wrapper interface
    bool isWrapper;
    /// @dev Whether the vault is linked to a tranche atm
    bool isLinked;
}

struct AssetIdKey {
    /// @dev The address of the asset
    address asset;
    /// @dev The ERC6909 token id or 0, if the underlying asset is an ERC20
    uint256 tokenId;
}

interface IPoolManager is IRecoverable {
    event File(bytes32 indexed what, address data);
    event RegisterAsset(
        uint128 indexed assetId,
        address indexed asset,
        uint256 indexed tokenId,
        string name,
        string symbol,
        uint8 decimals
    );
    event File(bytes32 indexed what, address factory, bool status);
    event AddPool(uint64 indexed poolId);
    event AddTranche(uint64 indexed poolId, bytes16 indexed trancheId, address token);
    event DeployVault(
        uint64 indexed poolId,
        bytes16 indexed trancheId,
        address indexed asset,
        uint256 tokenId,
        address factory,
        address vault
    );
    event PriceUpdate(
        uint64 indexed poolId,
        bytes16 indexed trancheId,
        address indexed asset,
        uint256 tokenId,
        uint256 price,
        uint64 computedAt
    );
    event TransferTrancheTokens(
        uint64 indexed poolId,
        bytes16 indexed trancheId,
        address indexed sender,
        uint64 destinationId,
        bytes32 destinationAddress,
        uint128 amount
    );
    event UpdateContract(uint64 indexed poolId, bytes16 indexed trancheId, address target, bytes payload);
    event LinkVault(
        uint64 indexed poolId, bytes16 indexed trancheId, address indexed asset, uint256 tokenId, address vault
    );
    event UnlinkVault(
        uint64 indexed poolId, bytes16 indexed trancheId, address indexed asset, uint256 tokenId, address vault
    );

    /// @notice Returns the asset address and tokenId associated with a given asset id.
    ///
    /// @param assetId The underlying internal uint128 assetId.
    /// @return asset The address of the asset linked to the given asset id.
    /// @return tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    function idToAsset(uint128 assetId) external view returns (address asset, uint256 tokenId);

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'gateway', 'investmentManager', 'trancheFactory',
    ///                'vaultFactory', or 'gasService'
    function file(bytes32 what, address data) external;

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'vaultFactory'
    function file(bytes32 what, address factory, bool status) external;

    /// @notice transfers tranche tokens to a cross-chain recipient address
    /// @dev    To transfer to evm chains, pad a 20 byte evm address with 12 bytes of 0
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  destinationId The destination chain id
    /// @param  recipient A bytes32 representation of the recipient address
    /// @param  amount The amount of tokens to transfer
    function transferTrancheTokens(
        uint64 poolId,
        bytes16 trancheId,
        uint32 destinationId,
        bytes32 recipient,
        uint128 amount
    ) external;

    /// @notice     Registers an ERC-20 or ERC-6909 asset in another chain.
    /// @dev        `decimals()` MUST return a `uint8` value between 2 and 18.
    ///             `name()` and `symbol()` MAY return no values.
    function registerAsset(address asset, uint256 tokenId, uint32 destinationChain)
        external
        returns (uint128 assetId);

    function deployVault(uint64 poolId, bytes16 trancheId, uint128 assetId, address factory)
        external
        returns (address);

    function linkVault(uint64 poolId, bytes16 trancheId, uint128 assetId, address vault) external;

    function unlinkVault(uint64 poolId, bytes16 trancheId, uint128 assetId, address vault) external;

    /// @notice Returns whether the given pool id is active
    function isPoolActive(uint64 poolId) external view returns (bool);

    /// @notice Returns the tranche token for a given pool and tranche id
    function tranche(uint64 poolId, bytes16 trancheId) external view returns (address);

    /// @notice Retuns the latest tranche token price for a given pool, tranche id, and asset
    function tranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId)
        external
        view
        returns (uint128 price, uint64 computedAt);

    /// @notice Function to get the details of a vault
    /// @dev    Reverts if vault does not exist
    ///
    /// @param vault The address of the vault to be checked for
    /// @return details The details of the vault including the underlying asset address, token id, asset id
    function vaultDetails(address vault) external view returns (VaultDetails memory details);

    /// @notice Checks whether a given asset-vault pair is eligible for investing into a tranche of a pool
    function isLinked(uint64 poolId, bytes16 trancheId, address asset, address vault) external view returns (bool);
}

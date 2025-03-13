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
    mapping(address asset => address[]) vaults;
    /// @dev Each tranche has a price per asset
    mapping(address asset => TranchePrice) prices;
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

struct VaultAsset {
    /// @dev Address of the asset
    address asset;
    /// @dev Whether this wrapper conforms to the IERC20Wrapper interface
    bool isWrapper;
    /// @dev Whether the vault is linked to a tranche atm
    bool isLinked;
}

interface IPoolManager is IRecoverable {
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, address factory, bool status);
    event AddAsset(uint128 indexed assetId, address indexed asset);
    event AddPool(uint64 indexed poolId);
    event AllowAsset(uint64 indexed poolId, address indexed asset);
    event DisallowAsset(uint64 indexed poolId, address indexed asset);
    event AddTranche(uint64 indexed poolId, bytes16 indexed trancheId, address token);
    event DeployVault(
        uint64 indexed poolId, bytes16 indexed trancheId, address indexed asset, address factory, address vault
    );
    event PriceUpdate(
        uint64 indexed poolId, bytes16 indexed trancheId, address indexed asset, uint256 price, uint64 computedAt
    );
    event TransferAssets(address indexed asset, address indexed sender, bytes32 indexed recipient, uint128 amount);
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
        uint64 indexed poolId, bytes16 indexed trancheId, uint128 indexed assetId, address asset, address vault
    );
    event UnlinkVault(
        uint64 indexed poolId, bytes16 indexed trancheId, uint128 indexed assetId, address asset, address vault
    );

    /// @notice returns the asset address associated with a given asset id
    function idToAsset(uint128 assetId) external view returns (address asset);

    /// @notice returns the asset id associated with a given address
    function assetToId(address) external view returns (uint128 assetId);

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

    /// @notice    New pool details from an existing Centrifuge pool are added.
    /// @dev       The function can only be executed by the gateway contract.
    function addPool(uint64 poolId) external;

    /// @notice     Centrifuge pools can support multiple currencies for investing. this function adds
    ///             a new supported asset to the pool details.
    ///             Adding new currencies allow the creation of new vaults for the underlying Centrifuge pool.
    /// @dev        The function can only be executed by the gateway contract.
    function allowAsset(uint64 poolId, uint128 assetId) external;

    /// @notice    Centrifuge pools can support multiple currencies for investing. this function removes
    ///            a supported asset from the pool details.
    /// @dev       The function can only be executed by the gateway contract.
    function disallowAsset(uint64 poolId, uint128 assetId) external;

    /// @notice     New tranche details from an existing Centrifuge pool are added.
    /// @dev        The function can only be executed by the gateway contract.
    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) external returns (address);

    /// @notice   Updates the tokenName and tokenSymbol of a tranche token
    /// @dev      The function can only be executed by the gateway contract.
    function updateTrancheMetadata(uint64 poolId, bytes16 trancheId, string memory tokenName, string memory tokenSymbol)
        external;

    /// @notice  Updates the price of a tranche token
    /// @dev     The function can only be executed by the gateway contract.
    function updateTranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId, uint128 price, uint64 computedAt)
        external;

    /// @notice Updates the restrictions on a tranche token for a specific user
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  update The restriction update in the form of a bytes array indicating
    ///                the restriction to be updated, the user to be updated, and a validUntil timestamp.
    function updateRestriction(uint64 poolId, bytes16 trancheId, bytes memory update) external;

    /// @notice Updates the target address. Generic update function from CP to CV
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  target The target address to be called
    /// @param  update The payload to be processed by the target address
    function updateContract(uint64 poolId, bytes16 trancheId, address target, bytes memory update) external;

    /// @notice Updates the hook of a tranche token
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  hook The new hook addres
    function updateTrancheHook(uint64 poolId, bytes16 trancheId, address hook) external;

    /// @notice A global chain agnostic asset index is maintained on Centrifuge. This function maps
    ///         a asset from the Centrifuge index to its corresponding address on the evm chain.
    ///         The chain agnostic asset id has to be used to pass asset information to the Centrifuge.
    /// @dev    This function can only be executed by the gateway contract.
    function addAsset(uint128 assetId, address asset) external;

    function deployVault(uint64 poolId, bytes16 trancheId, address asset, address factory) external returns (address);

    function linkVault(uint64 poolId, bytes16 trancheId, address asset, address vault) external;

    function unlinkVault(uint64 poolId, bytes16 trancheId, address asset, address vault) external;

    /// @notice Mints tranche tokens to a recipient
    /// @dev    The function can only be executed internally or by the gateway contract.
    function handleTransferTrancheTokens(uint64 poolId, bytes16 trancheId, address destinationAddress, uint128 amount)
        external;

    /// @notice Returns whether the given pool id is active
    function isPoolActive(uint64 poolId) external view returns (bool);

    /// @notice Returns the tranche token for a given pool and tranche id
    function getTranche(uint64 poolId, bytes16 trancheId) external view returns (address);

    /// @notice Retuns the latest tranche token price for a given pool, tranche id, and asset id
    function getTranchePrice(uint64 poolId, bytes16 trancheId, address asset)
        external
        view
        returns (uint128 price, uint64 computedAt);

    /// @notice Function to get the vault's underlying asset
    /// @dev    Function vaultToAsset which is a state variable getter could be used
    ///         but in that case each caller MUST make sure they handle the case
    ///         where a 0 address is returned. Using this method, that handling is done
    ///         on the behalf the caller.
    function getVaultAsset(address vault) external view returns (address asset, bool isWrapper);

    /// @notice Function to get the vault's underlying assetId
    /// @dev    Function getVaultAssetId handles non-existing vault errors and provides the underlying assetId of a
    /// vault
    function getVaultAssetId(address vault) external view returns (uint128);

    /// @notice Checks whether a given asset-vault pair is eligible for investing into a tranche of a pool
    function isLinked(uint64 poolId, bytes16 trancheId, address asset, address vault) external view returns (bool);

    // TODO: TEMP for
    function isAllowedAsset(uint64 poolId, address asset) external view returns (bool);
}

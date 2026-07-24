// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../../../misc/types/D18.sol";

import {PoolId} from "../../../types/PoolId.sol";
import {AssetId} from "../../../types/AssetId.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {ShareClassId} from "../../../types/ShareClassId.sol";
import {IShareToken} from "../../../../token/interfaces/IShareToken.sol";
import {ISpokeRequestManager} from "../../interfaces/ISpokeRequestManager.sol";
import {VaultDetails, ISpokeRegistry} from "../../interfaces/ISpokeRegistry.sol";

/// @title  ISpokeV3_1_0
/// @notice Legacy interface matching the Spoke contract as it existed in protocol v3.1.0,
///         before the spoke was split into Spoke and SpokeRegistry.
///         Most user interaction methods are omitted (e.g. registerAsset), except crosschainTransferShares
///         which is retained for integrators (e.g. Grove) that reach the spoke via the vault's manager.
/// @dev    DEPRECATED: This interface exists solely for backward compatibility with deployed vault
///         contracts (AsyncRequestManager, SyncManager) that were built against the pre-refactor
///         monolithic Spoke ABI. New contracts should depend on ISpoke and ISpokeRegistry directly.
interface ISpokeV3_1_0 {
    event File(bytes32 indexed what, address data);

    error FileUnrecognizedParam();
    error InvalidRequestManager();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts "spoke" or "spokeRegistry"
    /// @param data The new address
    function file(bytes32 what, address data) external;

    /// @notice See Spoke.request
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable;

    /// @notice See Spoke.crosschainTransferShares. Preserves the v3.1.0 signature; the caller is forwarded as
    ///         the share `owner` and must hold the bridger role.
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable;

    /// @notice See SpokeRegistry.idToAsset
    function idToAsset(AssetId assetId) external view returns (address asset, uint256 tokenId);

    /// @notice See SpokeRegistry.assetToId
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId);

    /// @notice See SpokeRegistry.isPoolActive
    function isPoolActive(PoolId poolId) external view returns (bool);

    /// @notice See SpokeRegistry.shareToken
    function shareToken(PoolId poolId, ShareClassId scId) external view returns (IShareToken);

    /// @notice See SpokeRegistry.pricePoolPerShare
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) external view returns (D18 price);

    /// @notice See SpokeRegistry.pricePoolPerAsset
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 price);

    /// @notice See SpokeRegistry.pricesPoolPer
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 pricePoolPerAsset, D18 pricePoolPerShare);

    /// @notice Synthesizes the v3.1.0 share-price age markers from SpokeRegistry.pricePoolPerShareComputedAt.
    /// @dev    Prices do not expire in core, so maxAge and validUntil are reported as unbounded.
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice Synthesizes the v3.1.0 asset-price age markers from SpokeRegistry.pricePoolPerAssetComputedAt.
    /// @dev    Prices do not expire in core, so maxAge and validUntil are reported as unbounded.
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice See SpokeRegistry.requestManager
    function requestManager(PoolId poolId) external view returns (ISpokeRequestManager manager);

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the details of a vault
    /// @dev Reverts if vault does not exist
    function vaultDetails(IVault vault) external view returns (VaultDetails memory details);

    /// @notice Checks whether a given vault is linked to a share class
    function isLinked(IVault vault) external view returns (bool);

    /// @notice Returns the address of the vault for a given pool, share class, asset and request manager
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId, ISpokeRequestManager manager)
        external
        view
        returns (IVault vaultAddress);
}

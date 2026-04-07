// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IShareToken} from "../../interfaces/IShareToken.sol";
import {IVault, VaultKind} from "../../interfaces/IVault.sol";

import {D18} from "../../../../misc/types/D18.sol";

import {AssetIdKey, Pool, ShareClassDetails, TokenDetails} from "../../interfaces/ISpokeRegistry.sol";
import {PoolId} from "../../../types/PoolId.sol";
import {AssetId} from "../../../types/AssetId.sol";
import {ShareClassId} from "../../../types/ShareClassId.sol";
import {IRequestManager} from "../../../interfaces/IRequestManager.sol";
import {IVaultFactory} from "../../factories/interfaces/IVaultFactory.sol";

/// @title  ISpokeV3_1_0
/// @notice Legacy interface matching the Spoke contract as it existed in protocol v3.1.0,
///         before the spoke was split into Spoke and SpokeRegistry.
///         User interaction methods are avoided (i.e: registerAsset or crosschain transfers)
interface ISpokeV3_1_0 {
    event File(bytes32 indexed what, address data);

    error FileUnrecognizedParam();

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

    /// @notice See SpokeRegistry.idToAsset
    function idToAsset(AssetId assetId) external view returns (address asset, uint256 tokenId);

    /// @notice See SpokeRegistry.assetToId
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId);

    /// @notice See SpokeRegistry.shareTokenDetails
    function shareTokenDetails(address shareToken_) external view returns (PoolId poolId, ShareClassId scId);

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

    /// @notice See SpokeRegistry.markersPricePoolPerShare
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice See SpokeRegistry.markersPricePoolPerAsset
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice See SpokeRegistry.requestManager
    function requestManager(PoolId poolId) external view returns (IRequestManager manager);
}

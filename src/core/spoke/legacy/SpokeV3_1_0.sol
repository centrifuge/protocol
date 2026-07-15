// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultDetails, ISpokeV3_1_0} from "./interfaces/ISpokeV3_1_0.sol";

import {Auth} from "../../../misc/Auth.sol";
import {D18} from "../../../misc/types/D18.sol";
import {Recoverable} from "../../../misc/Recoverable.sol";
import {CastLib} from "../../../misc/libraries/CastLib.sol";
import {ReentrancyProtection} from "../../../misc/ReentrancyProtection.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ISpoke} from "../interfaces/ISpoke.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {ISpokeRegistry} from "../interfaces/ISpokeRegistry.sol";
import {IRequestManager} from "../../interfaces/IRequestManager.sol";
import {IShareToken} from "../../../token/interfaces/IShareToken.sol";

/// @notice Thin wrapper over Spoke and SpokeRegistry to offer a Spoke v3.1.0 like interface
contract SpokeV3_1_0 is Auth, Recoverable, ReentrancyProtection, ISpokeV3_1_0 {
    using CastLib for *;

    ISpoke public spoke;
    ISpokeRegistry public spokeRegistry;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeV3_1_0
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeV3_1_0
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable {
        IRequestManager manager = spokeRegistry.requestManager(poolId);
        require(address(manager) != address(0), ISpokeV3_1_0.InvalidRequestManager());
        require(msg.sender == address(manager), NotAuthorized());

        spoke.sender().sendRequest{value: msg.value}(poolId, scId, assetId, payload, extraGasLimit, unpaid, refund);
    }

    /// @inheritdoc ISpokeV3_1_0
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable {
        spoke.crosschainTransferShares{value: msg.value}(
            centrifugeId, poolId, scId, receiver, msg.sender, msg.sender, amount, 0, remoteExtraGasLimit, msg.sender
        );
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeV3_1_0
    function idToAsset(AssetId assetId) external view returns (address asset, uint256 tokenId) {
        return spokeRegistry.idToAsset(assetId);
    }

    /// @inheritdoc ISpokeV3_1_0
    function assetToId(address asset, uint256 tokenId) external view returns (AssetId assetId) {
        return spokeRegistry.assetToId(asset, tokenId);
    }

    /// @inheritdoc ISpokeV3_1_0
    function isPoolActive(PoolId poolId) external view returns (bool) {
        return spokeRegistry.isPoolActive(poolId);
    }

    /// @inheritdoc ISpokeV3_1_0
    function shareToken(PoolId poolId, ShareClassId scId) external view returns (IShareToken) {
        return IShareToken(address(spokeRegistry.shareToken(poolId, scId)));
    }

    /// @inheritdoc ISpokeV3_1_0
    function pricePoolPerShare(PoolId poolId, ShareClassId scId, bool checkValidity) external view returns (D18 price) {
        return spokeRegistry.pricePoolPerShare(poolId, scId, checkValidity);
    }

    /// @inheritdoc ISpokeV3_1_0
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 price)
    {
        return spokeRegistry.pricePoolPerAsset(poolId, scId, assetId, checkValidity);
    }

    /// @inheritdoc ISpokeV3_1_0
    function pricesPoolPer(PoolId poolId, ShareClassId scId, AssetId assetId, bool checkValidity)
        external
        view
        returns (D18 pricePoolPerAsset_, D18 pricePoolPerShare_)
    {
        return (
            spokeRegistry.pricePoolPerAsset(poolId, scId, assetId, checkValidity),
            spokeRegistry.pricePoolPerShare(poolId, scId, checkValidity)
        );
    }

    /// @inheritdoc ISpokeV3_1_0
    /// @dev Prices do not expire in core; the v3.1.0 age markers report no maximum age.
    function markersPricePoolPerShare(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        return (spokeRegistry.pricePoolPerShareComputedAt(poolId, scId), type(uint64).max, type(uint64).max);
    }

    /// @inheritdoc ISpokeV3_1_0
    /// @dev Prices do not expire in core; the v3.1.0 age markers report no maximum age.
    function markersPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil)
    {
        return (spokeRegistry.pricePoolPerAssetComputedAt(poolId, scId, assetId), type(uint64).max, type(uint64).max);
    }

    /// @inheritdoc ISpokeV3_1_0
    function requestManager(PoolId poolId) external view returns (IRequestManager manager) {
        return spokeRegistry.requestManager(poolId);
    }

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeV3_1_0
    function vaultDetails(IVault vault_) external view returns (VaultDetails memory details) {
        return spokeRegistry.vaultDetails(vault_);
    }

    /// @inheritdoc ISpokeV3_1_0
    function isLinked(IVault vault_) external view returns (bool) {
        return spokeRegistry.isLinked(vault_);
    }

    /// @inheritdoc ISpokeV3_1_0
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager)
        external
        view
        returns (IVault)
    {
        return spokeRegistry.vault(poolId, scId, assetId, manager);
    }
}

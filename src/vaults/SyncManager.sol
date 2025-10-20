// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseVault} from "./interfaces/IBaseVault.sol";
import {IDepositManager} from "./interfaces/IVaultManagers.sol";
import {ISyncDepositManager} from "./interfaces/IVaultManagers.sol";
import {ISyncManager, ISyncDepositValuation} from "./interfaces/IVaultManagers.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {PricingLib} from "../core/libraries/PricingLib.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IShareToken} from "../core/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../core/utils/interfaces/IContractUpdate.sol";
import {VaultDetails, IVaultRegistry} from "../core/spoke/interfaces/IVaultRegistry.sol";

/// @title  Sync Manager
/// @notice This is the main contract for synchronous ERC-4626 deposits.
contract SyncManager is Auth, Recoverable, ISyncManager {
    using MathLib for *;
    using CastLib for *;
    using BytesLib for bytes;

    ISpoke public spoke;
    IBalanceSheet public balanceSheet;
    IVaultRegistry public vaultRegistry;

    mapping(PoolId => mapping(ShareClassId => ISyncDepositValuation)) public valuation;
    mapping(PoolId => mapping(ShareClassId => mapping(address asset => mapping(uint256 tokenId => uint128)))) public
        maxReserve;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISyncManager
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "vaultRegistry") vaultRegistry = IVaultRegistry(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes memory payload) external auth {
        uint8 kindValue = abi.decode(payload, (uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.Valuation) {
            (, bytes32 valuation_) = abi.decode(payload, (uint8, bytes32));
            require(address(spoke.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());

            setValuation(poolId, scId, valuation_.toAddress());
        } else if (kind == TrustedCall.MaxReserve) {
            (, uint128 assetId, uint128 maxReserve_) = abi.decode(payload, (uint8, uint128, uint128));
            require(address(spoke.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());

            (address asset, uint256 tokenId) = spoke.idToAsset(AssetId.wrap(assetId));
            setMaxReserve(poolId, scId, asset, tokenId, maxReserve_);
        }
    }

    /// @inheritdoc ISyncManager
    function setValuation(PoolId poolId, ShareClassId scId, address valuation_) public auth {
        valuation[poolId][scId] = ISyncDepositValuation(valuation_);

        emit SetValuation(poolId, scId, address(valuation_));
    }

    /// @inheritdoc ISyncManager
    function setMaxReserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 maxReserve_)
        public
        auth
    {
        maxReserve[poolId][scId][asset][tokenId] = maxReserve_;

        emit SetMaxReserve(poolId, scId, asset, tokenId, maxReserve_);
    }

    //----------------------------------------------------------------------------------------------
    // Deposit handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function mint(IBaseVault vault_, uint256 shares, address receiver, address owner)
        external
        auth
        returns (uint256 assets)
    {
        require(maxMint(vault_, owner) >= shares, ExceedsMaxMint());
        assets = previewMint(vault_, owner, shares);

        _issueShares(vault_, shares.toUint128(), receiver, assets.toUint128());
    }

    /// @inheritdoc IDepositManager
    function deposit(IBaseVault vault_, uint256 assets, address receiver, address owner)
        external
        auth
        returns (uint256 shares)
    {
        require(maxDeposit(vault_, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vault_, owner, assets);

        _issueShares(vault_, shares.toUint128(), receiver, assets.toUint128());
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISyncDepositManager
    function previewMint(IBaseVault vault_, address, uint256 shares) public view returns (uint256 assets) {
        return _shareToAssetAmount(vault_, shares, MathLib.Rounding.Up);
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(IBaseVault vault_, address, uint256 assets) public view returns (uint256 shares) {
        return convertToShares(vault_, assets);
    }

    /// @inheritdoc IDepositManager
    function maxMint(IBaseVault vault_, address owner) public view returns (uint256 shares) {
        VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(vault_);
        uint128 maxAssets =
            _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId, vault_);
        (, shares) = _maxAssetsAndShares(vault_, maxAssets, vaultDetails);
        if (!_canTransfer(vault_, address(0), owner, shares)) return 0;
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address owner) public view returns (uint256 assets) {
        VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(vault_);
        uint128 maxAssets =
            _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId, vault_);

        uint256 shares;
        (assets, shares) = _maxAssetsAndShares(vault_, maxAssets, vaultDetails);

        if (shares == 0 || !_canTransfer(vault_, address(0), owner, shares)) return 0;
    }

    /// @inheritdoc ISyncManager
    function convertToShares(IBaseVault vault_, uint256 assets) public view returns (uint256 shares) {
        VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(vault_);

        D18 poolPerShare = pricePoolPerShare(vault_.poolId(), vault_.scId());
        D18 poolPerAsset = spoke.pricePoolPerAsset(vault_.poolId(), vault_.scId(), vaultDetails.assetId, true);

        return poolPerShare.isZero()
            ? 0
            : PricingLib.assetToShareAmount(
                vault_.share(),
                vaultDetails.asset,
                vaultDetails.tokenId,
                assets.toUint128(),
                poolPerAsset,
                poolPerShare,
                MathLib.Rounding.Down
            );
    }

    /// @inheritdoc ISyncManager
    function convertToAssets(IBaseVault vault_, uint256 shares) public view returns (uint256 assets) {
        return _shareToAssetAmount(vault_, shares, MathLib.Rounding.Down);
    }

    /// @inheritdoc ISyncDepositValuation
    function pricePoolPerShare(PoolId poolId, ShareClassId scId) public view returns (D18 price) {
        ISyncDepositValuation valuation_ = valuation[poolId][scId];

        if (address(valuation_) == address(0)) {
            price = spoke.pricePoolPerShare(poolId, scId, true);
        } else {
            price = valuation_.pricePoolPerShare(poolId, scId);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev Issues shares to the receiver and instruct the balance sheet
    //       to react on the issuance and the updated holding.
    function _issueShares(IBaseVault vault_, uint128 shares, address receiver, uint128 assets) internal {
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();
        VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(vault_);

        // Note deposit into the pool escrow, to make assets available for managers of the balance sheet.
        // ERC-20 transfer is handled by the vault to the pool escrow afterwards.
        balanceSheet.noteDeposit(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, assets);

        // Mint shares to the receiver.
        balanceSheet.overridePricePoolPerShare(poolId, scId, pricePoolPerShare(poolId, scId));
        balanceSheet.issue(poolId, scId, receiver, shares);
        balanceSheet.resetPricePoolPerShare(poolId, scId);
    }

    function _maxDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, IBaseVault vault_)
        internal
        view
        returns (uint128 maxDeposit_)
    {
        if (!vaultRegistry.isLinked(vault_)) return 0;

        uint128 availableBalance = balanceSheet.availableBalanceOf(poolId, scId, asset, tokenId);
        uint128 maxReserve_ = maxReserve[poolId][scId][asset][tokenId];

        if (maxReserve_ < availableBalance) {
            maxDeposit_ = 0;
        } else {
            maxDeposit_ = maxReserve_ - availableBalance;
        }
    }

    function _shareToAssetAmount(IBaseVault vault_, uint256 shares, MathLib.Rounding rounding)
        internal
        view
        returns (uint256 assets)
    {
        VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(vault_);

        D18 poolPerShare = pricePoolPerShare(vault_.poolId(), vault_.scId());
        D18 poolPerAsset = spoke.pricePoolPerAsset(vault_.poolId(), vault_.scId(), vaultDetails.assetId, true);

        return poolPerAsset.isZero()
            ? 0
            : PricingLib.shareToAssetAmount(
                vault_.share(),
                shares.toUint128(),
                vaultDetails.asset,
                vaultDetails.tokenId,
                poolPerShare,
                poolPerAsset,
                rounding
            );
    }

    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(IBaseVault vault_, address from, address to, uint256 value) internal view returns (bool) {
        IShareToken share = IShareToken(vault_.share());
        return share.checkTransferRestriction(from, to, value);
    }

    /// @dev    Calculates safe maximum assets and corresponding shares, handling overflow and zero prices correctly.
    function _maxAssetsAndShares(IBaseVault vault_, uint256 maxAssets, VaultDetails memory vaultDetails)
        internal
        view
        returns (uint256 clampedAssets, uint256 shares)
    {
        uint128 maxConvertible = _maxConvertibleAssets(vault_, vaultDetails);
        clampedAssets = maxAssets < maxConvertible ? maxAssets : maxConvertible;

        // NOTE: Returns 0 if any price is zero
        shares = convertToShares(vault_, clampedAssets);
    }

    /// @dev    Calculates the maximum amount of assets that can be converted to shares without uint128 overflow.
    ///         Uses PricingLib to determine safe input bounds based on inverse conversion formula.
    function _maxConvertibleAssets(IBaseVault vault_, VaultDetails memory vaultDetails)
        internal
        view
        returns (uint128)
    {
        D18 poolPerShare = pricePoolPerShare(vault_.poolId(), vault_.scId());
        D18 poolPerAsset = spoke.pricePoolPerAsset(vault_.poolId(), vault_.scId(), vaultDetails.assetId, true);

        if (poolPerShare.isZero() || poolPerAsset.isZero()) return 0;

        uint256 maxAssets = PricingLib.maxConvertibleAssetAmount(
            vault_.share(), vaultDetails.asset, vaultDetails.tokenId, type(uint128).max, poolPerShare, poolPerAsset
        );

        // Clamp to uint128 if calculation exceeds max
        return maxAssets > type(uint128).max ? type(uint128).max : uint128(maxAssets);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {d18, D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IERC7540Redeem, IAsyncRedeemVault, IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {ISharePriceProvider, Prices} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncRequests is BaseInvestmentManager, ISyncRequests {
    using BytesLib for bytes;
    using MathLib for *;
    using CastLib for *;
    using MessageLib for *;

    IBalanceSheet public balanceSheet;

    mapping(uint64 poolId => mapping(bytes16 scId => mapping(uint128 assetId => address))) public vault;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => uint128))))
        public maxReserve;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => IERC7726))))
        public valuation;

    constructor(IPoolEscrow globalEscrow_, address root_, address deployer)
        BaseInvestmentManager(globalEscrow_, root_, deployer)
    {}

    // --- Administration ---
    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// --- IUpdateContract ---
    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId scId, bytes memory payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.Valuation)) {
            MessageLib.UpdateContractValuation memory m = MessageLib.deserializeUpdateContractValuation(payload);

            require(address(poolManager.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());
            (address asset, uint256 tokenId) = poolManager.idToAsset(AssetId.wrap(m.assetId));

            setValuation(poolId.raw(), scId.raw(), asset, tokenId, m.valuation.toAddress());
        } else if (kind == uint8(UpdateContractType.SyncDepositMaxReserve)) {
            MessageLib.UpdateContractSyncDepositMaxReserve memory m =
                MessageLib.deserializeUpdateContractSyncDepositMaxReserve(payload);

            require(address(poolManager.shareToken(poolId, scId)) != address(0), ShareTokenDoesNotExist());
            (address asset, uint256 tokenId) = poolManager.idToAsset(AssetId.wrap(m.assetId));

            setMaxReserve(poolId.raw(), scId.raw(), asset, tokenId, m.maxReserve);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId)
        external
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        require(vault_.asset() == asset_, AssetMismatch());
        require(vault[poolId][scId][assetId] == address(0), VaultAlreadyExists());

        address token = vault_.share();
        vault[poolId][scId][assetId] = vaultAddr;

        (, uint256 tokenId) = poolManager.idToAsset(AssetId.wrap(assetId));
        setMaxReserve(poolId, scId, asset_, tokenId, type(uint128).max);

        IAuth(token).rely(vaultAddr);
        IShareToken(token).updateVault(asset_, vaultAddr);
        rely(vaultAddr);

        (VaultKind vaultKind_, address secondaryManager) = vaultKind(vaultAddr);
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IVaultManager(secondaryManager).addVault(poolId, scId, vaultAddr, asset_, assetId);
        }
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId)
        external
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(vault[poolId][scId][assetId] != address(0), VaultDoesNotExist());

        delete vault[poolId][scId][assetId];

        (, uint256 tokenId) = poolManager.idToAsset(AssetId.wrap(assetId));
        delete maxReserve[poolId][scId][asset_][tokenId];

        IAuth(token).deny(vaultAddr);
        IShareToken(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);

        (VaultKind vaultKind_, address secondaryManager) = vaultKind(vaultAddr);
        if (vaultKind_ == VaultKind.SyncDepositAsyncRedeem) {
            IVaultManager(secondaryManager).removeVault(poolId, scId, vaultAddr, asset_, assetId);
        }
    }

    // --- IDepositManager Writes ---
    /// @inheritdoc IDepositManager
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        auth
        returns (uint256 assets)
    {
        require(maxMint(vaultAddr, owner) >= shares, ExceedsMaxMint());
        assets = previewMint(vaultAddr, owner, shares);

        _issueShares(vaultAddr, shares.toUint128(), receiver, owner, assets.toUint128());
    }

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        auth
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        _issueShares(vaultAddr, shares.toUint128(), receiver, owner, assets.toUint128());
    }

    /// @inheritdoc ISyncRequests
    function setValuation(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address valuation_)
        public
        auth
    {
        valuation[poolId][scId][asset][tokenId] = IERC7726(valuation_);

        emit SetValuation(poolId, scId, asset, tokenId, address(valuation_));
    }

    /// @inheritdoc ISyncRequests
    function setMaxReserve(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, uint128 maxReserve_)
        public
        auth
    {
        maxReserve[poolId][scId][asset][tokenId] = maxReserve_;

        emit SetMaxReserve(poolId, scId, asset, tokenId, maxReserve_);
    }

    // --- ISyncDepositManager Reads ---
    /// @inheritdoc ISyncDepositManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        return convertToAssets(vaultAddr, shares);
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        return convertToShares(vaultAddr, assets);
    }

    // --- IDepositManager Reads ---
    /// @inheritdoc IDepositManager
    function maxMint(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        uint128 maxAssets = _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId);
        return convertToShares(vaultAddr, maxAssets);
    }

    /// @inheritdoc IDepositManager
    function maxDeposit(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        return _maxDeposit(vault_.poolId(), vault_.scId(), vaultDetails.asset, vaultDetails.tokenId);
    }

    // --- IVaultManager Views ---
    /// @inheritdoc IVaultManager
    function vaultByAssetId(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (address) {
        return vault[poolId][scId][assetId];
    }

    /// @inheritdoc IVaultManager
    function vaultKind(address vaultAddr) public view returns (VaultKind, address) {
        if (IERC165(vaultAddr).supportsInterface(type(IERC7540Redeem).interfaceId)) {
            return (VaultKind.SyncDepositAsyncRedeem, address(IAsyncRedeemVault(vaultAddr).asyncRedeemManager()));
        } else {
            return (VaultKind.Sync, address(0));
        }
    }

    // --- IBaseInvestmentManager Overwrites ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(address vaultAddr, uint256 assets)
        public
        view
        override(IBaseInvestmentManager, BaseInvestmentManager)
        returns (uint256 shares)
    {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        D18 priceAssetPerShare_ = _priceAssetPerShare(
            vault_.poolId(), vault_.scId(), vaultDetails.assetId.raw(), vault_.asset(), vaultDetails.tokenId
        );

        return super._convertToShares(vault_, vaultDetails, priceAssetPerShare_, assets, MathLib.Rounding.Down);
    }

    // --- IBaseInvestmentManager Overwrites ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(address vaultAddr, uint256 shares)
        public
        view
        override(IBaseInvestmentManager, BaseInvestmentManager)
        returns (uint256 assets)
    {
        IBaseVault vault_ = IBaseVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        D18 priceAssetPerShare_ = _priceAssetPerShare(
            vault_.poolId(), vault_.scId(), vaultDetails.assetId.raw(), vault_.asset(), vaultDetails.tokenId
        );

        return super._convertToAssets(vault_, vaultDetails, priceAssetPerShare_, shares, MathLib.Rounding.Up);
    }

    // --- ISharePriceProvider Overwrites ---
    /// @inheritdoc ISharePriceProvider
    function priceAssetPerShare(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (D18 price) {
        (address asset, uint256 tokenId) = poolManager.idToAsset(AssetId.wrap(assetId));

        return _priceAssetPerShare(poolId, scId, assetId, asset, tokenId);
    }

    /// @inheritdoc ISharePriceProvider
    function prices(uint64 poolId, bytes16 scId, uint128 assetId, address asset, uint256 tokenId)
        public
        view
        returns (Prices memory priceData)
    {
        IERC7726 valuation_ = valuation[poolId][scId][asset][tokenId];

        (priceData.poolPerAsset,) =
            poolManager.pricePoolPerAsset(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), true);
        priceData.assetPerShare = _priceAssetPerShare(poolId, scId, assetId, asset, tokenId, valuation_);

        if (address(valuation_) == address(0)) {
            (priceData.poolPerShare,) =
                poolManager.pricePoolPerShare(PoolId.wrap(poolId), ShareClassId.wrap(scId), true);
        } else {
            priceData.poolPerShare = priceData.poolPerAsset * priceData.assetPerShare;
        }
    }

    /// --- Internal methods ---
    /// @dev Issues shares to the receiver and instruct the Balance Sheet Manager to react on the issuance and the
    /// updated holding
    function _issueShares(
        address vaultAddr,
        uint128 shares,
        address receiver,
        address owner,
        uint128 depositAssetAmount
    ) internal {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        PoolId poolId = PoolId.wrap(vault_.poolId());
        ShareClassId scId = ShareClassId.wrap(vault_.scId());
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);

        Prices memory priceData =
            prices(poolId.raw(), scId.raw(), vaultDetails.assetId.raw(), vault_.asset(), vaultDetails.tokenId);

        // Mint shares for receiver & notify CP about issued shares
        balanceSheet.issue(poolId, scId, receiver, priceData.poolPerShare, shares);

        // NOTE:
        // - Transfer is handled by the vault to the pool escrow afterwards
        balanceSheet.noteDeposit(
            poolId, scId, vaultDetails.asset, vaultDetails.tokenId, receiver, depositAssetAmount, priceData.poolPerAsset
        );
    }

    function _maxDeposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId)
        internal
        view
        returns (uint128 maxDeposit_)
    {
        uint128 availableBalance =
            poolEscrowProvider.escrow(poolId).availableBalanceOf(scId, asset, tokenId).toUint128();
        uint128 maxReserve_ = maxReserve[poolId][scId][asset][tokenId];

        if (maxReserve_ < availableBalance) {
            maxDeposit_ = 0;
        } else {
            maxDeposit_ = maxReserve_ - availableBalance;
        }
    }

    function _priceAssetPerShare(uint64 poolId, bytes16 scId, uint128 assetId, address asset, uint256 tokenId)
        internal
        view
        returns (D18 price)
    {
        IERC7726 valuation_ = valuation[poolId][scId][asset][tokenId];

        return _priceAssetPerShare(poolId, scId, assetId, asset, tokenId, valuation_);
    }

    function _priceAssetPerShare(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address asset,
        uint256 tokenId,
        IERC7726 valuation_
    ) internal view returns (D18 price) {
        if (address(valuation_) == address(0)) {
            (price,) = poolManager.priceAssetPerShare(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), true
            );
        } else {
            IShareToken shareToken = poolManager.shareToken(PoolId.wrap(poolId), ShareClassId.wrap(scId));

            uint128 assetUnitAmount = uint128(10 ** VaultPricingLib.getAssetDecimals(asset, tokenId));
            uint128 shareUnitAmount = uint128(10 ** IERC20Metadata(shareToken).decimals());
            uint128 assetAmountPerShareUnit =
                valuation_.getQuote(shareUnitAmount, address(shareToken), asset).toUint128();

            // Retrieve price by normalizing by asset denomination
            price = d18(assetAmountPerShareUnit, assetUnitAmount);
        }
    }
}

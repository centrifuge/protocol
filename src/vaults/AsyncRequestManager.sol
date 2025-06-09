// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {RequestMessageLib} from "src/common/libraries/RequestMessageLib.sol";
import {RequestCallbackType, RequestCallbackMessageLib} from "src/common/libraries/RequestCallbackMessageLib.sol";
import {ESCROW_HOOK_ID} from "src/common/interfaces/ITransferHook.sol";

import {ISpoke, VaultDetails} from "src/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "src/spoke/interfaces/IBalanceSheet.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IRequestCallback} from "src/spoke/interfaces/IRequestCallback.sol";

import {IAsyncRequestManager, AsyncInvestmentState} from "src/vaults/interfaces/IVaultManagers.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {IAsyncDepositManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {IDepositManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {IRedeemManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {IBaseRequestManager} from "src/vaults/interfaces/IBaseRequestManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault, IAsyncRedeemVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {BaseRequestManager} from "src/vaults/BaseRequestManager.sol";

/// @title  Async Request Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncRequestManager is BaseRequestManager, IAsyncRequestManager {
    using CastLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    mapping(IBaseVault vault => mapping(address investor => AsyncInvestmentState)) public investments;

    constructor(IEscrow globalEscrow_, address root_, address deployer)
        BaseRequestManager(globalEscrow_, root_, deployer)
    {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external override(IBaseRequestManager, BaseRequestManager) auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Async investment handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAsyncDepositManager
    function requestDeposit(IBaseVault vault_, uint256 assets, address controller, address, address)
        public
        auth
        returns (bool)
    {
        uint128 assets_ = assets.toUint128();
        require(assets_ != 0, ZeroAmountNotAllowed());

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        require(spoke.isLinked(vault_), AssetNotAllowed());

        require(_canTransfer(vault_, address(0), controller, convertToShares(vault_, assets_)), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());

        state.pendingDepositRequest += assets_;
        _sendDepositRequest(poolId, scId, vaultDetails.assetId, controller, assets_);

        return true;
    }

    function _sendDepositRequest(PoolId poolId, ShareClassId scId, AssetId assetId, address controller, uint128 assets)
        internal
    {
        spoke.request(
            poolId, scId, assetId, RequestMessageLib.DepositRequest(controller.toBytes32(), assets).serialize()
        );
    }

    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(IBaseVault vault_, uint256 shares, address controller, address owner, address sender_)
        public
        auth
        returns (bool)
    {
        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmountNotAllowed());

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        require(spoke.isLinked(vault_), AssetNotAllowed());

        require(
            _canTransfer(vault_, owner, ESCROW_HOOK_ID, shares)
                && _canTransfer(vault_, controller, ESCROW_HOOK_ID, shares),
            TransferNotAllowed()
        );

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares_;
        _sendRedeemRequest(poolId, scId, vaultDetails.assetId, controller, shares_);
        _executeRedeemTransfer(poolId, scId, sender_, owner, address(globalEscrow), shares_);

        return true;
    }

    function _sendRedeemRequest(PoolId poolId, ShareClassId scId, AssetId assetId, address controller, uint128 shares)
        internal
    {
        spoke.request(
            poolId, scId, assetId, RequestMessageLib.RedeemRequest(controller.toBytes32(), shares).serialize()
        );
    }

    function _executeRedeemTransfer(
        PoolId poolId,
        ShareClassId scId,
        address sender_,
        address owner,
        address to,
        uint128 shares
    ) internal {
        balanceSheet.transferSharesFrom(poolId, scId, sender_, owner, to, shares);
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(IBaseVault vault_, address controller, address) public auth {
        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingDepositRequest > 0, NoPendingRequest());
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());
        state.pendingCancelDepositRequest = true;

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        spoke.request(
            vault_.poolId(),
            vault_.scId(),
            vaultDetails.assetId,
            RequestMessageLib.CancelDepositRequest(controller.toBytes32()).serialize()
        );
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(IBaseVault vault_, address controller, address) public auth {
        uint256 approximateSharesPayout = pendingRedeemRequest(vault_, controller);
        require(approximateSharesPayout > 0, NoPendingRequest());
        require(_canTransfer(vault_, address(0), controller, approximateSharesPayout), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());
        state.pendingCancelRedeemRequest = true;

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        spoke.request(
            vault_.poolId(),
            vault_.scId(),
            vaultDetails.assetId,
            RequestMessageLib.CancelRedeemRequest(controller.toBytes32()).serialize()
        );
    }

    //----------------------------------------------------------------------------------------------
    // Gateway handlers
    //----------------------------------------------------------------------------------------------

    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external {
        uint8 kind = uint8(RequestCallbackMessageLib.requestCallbackType(payload));

        if (kind == uint8(RequestCallbackType.ApprovedDeposits)) {
            RequestCallbackMessageLib.ApprovedDeposits memory m = payload.deserializeApprovedDeposits();
            approvedDeposits(poolId, scId, assetId, m.assetAmount, D18.wrap(m.pricePoolPerAsset));
        } else if (kind == uint8(RequestCallbackType.IssuedShares)) {
            RequestCallbackMessageLib.IssuedShares memory m = payload.deserializeIssuedShares();
            issuedShares(poolId, scId, m.shareAmount, D18.wrap(m.pricePoolPerShare));
        } else if (kind == uint8(RequestCallbackType.RevokedShares)) {
            RequestCallbackMessageLib.RevokedShares memory m = payload.deserializeRevokedShares();
            revokedShares(poolId, scId, assetId, m.assetAmount, m.shareAmount, D18.wrap(m.pricePoolPerShare));
        } else if (kind == uint8(RequestCallbackType.FulfilledDepositRequest)) {
            RequestCallbackMessageLib.FulfilledDepositRequest memory m = payload.deserializeFulfilledDepositRequest();
            fulfillDepositRequest(
                poolId,
                scId,
                m.investor.toAddress(),
                assetId,
                m.fulfilledAssetAmount,
                m.fulfilledShareAmount,
                m.cancelledAssetAmount
            );
        } else if (kind == uint8(RequestCallbackType.FulfilledRedeemRequest)) {
            RequestCallbackMessageLib.FulfilledRedeemRequest memory m = payload.deserializeFulfilledRedeemRequest();
            fulfillRedeemRequest(
                poolId,
                scId,
                m.investor.toAddress(),
                assetId,
                m.fulfilledAssetAmount,
                m.fulfilledShareAmount,
                m.cancelledShareAmount
            );
        } else {
            revert IRequestCallback.UnknownRequestCallbackType();
        }
    }

    /// @inheritdoc IAsyncRequestManager
    function approvedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) public auth {
        (address asset, uint256 tokenId) = spoke.idToAsset(assetId);

        // Note deposit and transfer from global escrow into the pool escrow,
        // to make assets available for managers of the balance sheet
        balanceSheet.overridePricePoolPerAsset(poolId, scId, assetId, pricePoolPerAsset);
        balanceSheet.noteDeposit(poolId, scId, asset, tokenId, assetAmount);
        balanceSheet.resetPricePoolPerAsset(poolId, scId, assetId);

        address poolEscrow = address(balanceSheet.escrow(poolId));
        globalEscrow.authTransferTo(asset, tokenId, poolEscrow, assetAmount);
    }

    /// @inheritdoc IAsyncRequestManager
    function issuedShares(PoolId poolId, ShareClassId scId, uint128 shareAmount, D18 pricePoolPerShare) public auth {
        balanceSheet.overridePricePoolPerShare(poolId, scId, pricePoolPerShare);
        balanceSheet.issue(poolId, scId, address(globalEscrow), shareAmount);
        balanceSheet.resetPricePoolPerShare(poolId, scId);
    }

    /// @inheritdoc IAsyncRequestManager
    function revokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) public auth {
        // Lock assets to ensure they are not withdrawn and are available for the redeeming user
        (address asset, uint256 tokenId) = spoke.idToAsset(assetId);
        balanceSheet.reserve(poolId, scId, asset, tokenId, assetAmount);

        globalEscrow.authTransferTo(address(spoke.shareToken(poolId, scId)), 0, address(this), shareAmount);
        balanceSheet.overridePricePoolPerShare(poolId, scId, pricePoolPerShare);
        balanceSheet.revoke(poolId, scId, shareAmount);
        balanceSheet.resetPricePoolPerShare(poolId, scId);
    }

    /// @inheritdoc IAsyncRequestManager
    function fulfillDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssets,
        uint128 fulfilledShares,
        uint128 cancelledAssets
    ) public auth {
        IAsyncVault vault_ = IAsyncVault(address(vault[poolId][scId][assetId]));
        AsyncInvestmentState storage state = investments[vault_][user];

        require(state.pendingDepositRequest != 0, NoPendingRequest());
        if (cancelledAssets > 0) {
            require(state.pendingCancelDepositRequest == true, NoPendingRequest());
            state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + cancelledAssets;
        }

        state.depositPrice = _calculatePriceAssetPerShare(
            vault_, state.maxMint + fulfilledShares, _maxDeposit(vault_, user) + fulfilledAssets, MathLib.Rounding.Down
        );
        state.maxMint = state.maxMint + fulfilledShares;
        state.pendingDepositRequest = state.pendingDepositRequest > fulfilledAssets + cancelledAssets
            ? state.pendingDepositRequest - fulfilledAssets - cancelledAssets
            : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        if (fulfilledAssets > 0) vault_.onDepositClaimable(user, fulfilledAssets, fulfilledShares);
        if (cancelledAssets > 0) vault_.onCancelDepositClaimable(user, cancelledAssets);
    }

    /// @inheritdoc IAsyncRequestManager
    function fulfillRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssets,
        uint128 fulfilledShares,
        uint128 cancelledShares
    ) public auth {
        IAsyncRedeemVault vault_ = IAsyncRedeemVault(address(vault[poolId][scId][assetId]));

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingRedeemRequest != 0, NoPendingRequest());

        if (cancelledShares > 0) {
            require(state.pendingCancelRedeemRequest, NoPendingRequest());
            state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + cancelledShares;
        }

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice = _calculatePriceAssetPerShare(
            vault_,
            ((maxRedeem(vault_, user)) + fulfilledShares).toUint128(),
            state.maxWithdraw + fulfilledAssets,
            MathLib.Rounding.Down
        );
        state.maxWithdraw = state.maxWithdraw + fulfilledAssets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > fulfilledShares + cancelledShares
            ? state.pendingRedeemRequest - fulfilledShares - cancelledShares
            : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        if (fulfilledShares > 0) vault_.onRedeemClaimable(user, fulfilledAssets, fulfilledShares);
        if (cancelledShares > 0) vault_.onCancelRedeemClaimable(user, cancelledShares);
    }

    //----------------------------------------------------------------------------------------------
    // Sync investment handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function deposit(IBaseVault vault_, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vault_, controller), ExceedsMaxDeposit());

        AsyncInvestmentState storage state = investments[vault_][controller];

        uint128 sharesUp = _assetToShareAmount(vault_, assets.toUint128(), state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _assetToShareAmount(vault_, assets.toUint128(), state.depositPrice, MathLib.Rounding.Down);
        shares = uint256(sharesDown);
        _processDeposit(state, sharesUp, sharesDown, vault_, receiver);
    }

    /// @inheritdoc IDepositManager
    function mint(IBaseVault vault_, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        AsyncInvestmentState storage state = investments[vault_][controller];
        uint128 shares_ = shares.toUint128();

        assets = uint256(_shareToAssetAmount(vault_, shares_, state.depositPrice, MathLib.Rounding.Up));
        _processDeposit(state, shares_, shares_, vault_, receiver);
    }

    function _processDeposit(
        AsyncInvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        IBaseVault vault_,
        address receiver
    ) internal {
        require(sharesUp <= state.maxMint, ExceedsDepositLimits());
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;

        if (sharesDown > 0) {
            globalEscrow.authTransferTo(vault_.share(), receiver, sharesDown);
        }
    }

    /// @inheritdoc IRedeemManager
    function redeem(IBaseVault vault_, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vault_, controller), ExceedsMaxRedeem());

        AsyncInvestmentState storage state = investments[vault_][controller];

        uint128 assetsUp = _shareToAssetAmount(vault_, shares.toUint128(), state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _shareToAssetAmount(vault_, shares.toUint128(), state.redeemPrice, MathLib.Rounding.Down);
        _processRedeem(state, assetsUp, assetsDown, vault_, receiver, controller);
        assets = uint256(assetsDown);
    }

    /// @inheritdoc IRedeemManager
    function withdraw(IBaseVault vault_, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        AsyncInvestmentState storage state = investments[vault_][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vault_, receiver, controller);

        shares = uint256(_assetToShareAmount(vault_, assets_, state.redeemPrice, MathLib.Rounding.Up));
    }

    function _processRedeem(
        AsyncInvestmentState storage state,
        uint128 assetsUp,
        uint128 assetsDown,
        IBaseVault vault_,
        address receiver,
        address controller
    ) internal {
        if (controller != receiver) {
            require(
                _canTransfer(vault_, controller, receiver, convertToShares(vault_, assetsDown)), TransferNotAllowed()
            );
        }

        require(_canTransfer(vault_, receiver, address(0), convertToShares(vault_, assetsDown)), TransferNotAllowed());

        require(assetsUp <= state.maxWithdraw, ExceedsRedeemLimits());
        state.maxWithdraw = state.maxWithdraw > assetsUp ? state.maxWithdraw - assetsUp : 0;

        if (assetsDown > 0) {
            _withdraw(vault_, receiver, assetsDown);
        }
    }

    /// @dev Transfer funds from escrow to receiver and update holdings
    function _withdraw(IBaseVault vault_, address receiver, uint128 assets) internal {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);

        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        balanceSheet.unreserve(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, assets);
        balanceSheet.withdraw(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, receiver, assets);
    }

    //----------------------------------------------------------------------------------------------
    // Cancellation claim handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAsyncDepositManager
    function claimCancelDepositRequest(IBaseVault vault_, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        AsyncInvestmentState storage state = investments[vault_][controller];
        assets = state.claimableCancelDepositRequest;
        state.claimableCancelDepositRequest = 0;
        uint256 shares = convertToShares(vault_, assets);

        if (controller != receiver) {
            require(_canTransfer(vault_, controller, receiver, shares), TransferNotAllowed());
        }
        require(_canTransfer(vault_, receiver, address(0), shares), TransferNotAllowed());

        if (assets > 0) {
            VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
            globalEscrow.authTransferTo(vaultDetails.asset, vaultDetails.tokenId, receiver, assets);
        }
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimCancelRedeemRequest(IBaseVault vault_, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        AsyncInvestmentState storage state = investments[vault_][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;

        if (shares > 0) {
            globalEscrow.authTransferTo(vault_.share(), receiver, shares);
        }
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vault_, ESCROW_HOOK_ID, user, 0)) {
            return 0;
        }
        assets = uint256(_maxDeposit(vault_, user));
    }

    function _maxDeposit(IBaseVault vault_, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vault_][user];

        assets = _shareToAssetAmount(vault_, state.maxMint, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function maxMint(IBaseVault vault_, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vault_, ESCROW_HOOK_ID, user, 0)) {
            return 0;
        }
        shares = uint256(investments[vault_][user].maxMint);
    }

    /// @inheritdoc IRedeemManager
    function maxWithdraw(IBaseVault vault_, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vault_, user, address(0), 0)) return 0;
        assets = uint256(investments[vault_][user].maxWithdraw);
    }

    /// @inheritdoc IRedeemManager
    function maxRedeem(IBaseVault vault_, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vault_, user, address(0), 0)) return 0;
        AsyncInvestmentState memory state = investments[vault_][user];

        shares = uint256(_assetToShareAmount(vault_, state.maxWithdraw, state.redeemPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IAsyncDepositManager
    function pendingDepositRequest(IBaseVault vault_, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vault_][user].pendingDepositRequest);
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingRedeemRequest(IBaseVault vault_, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vault_][user].pendingRedeemRequest);
    }

    /// @inheritdoc IAsyncDepositManager
    function pendingCancelDepositRequest(IBaseVault vault_, address user) public view returns (bool isPending) {
        isPending = investments[vault_][user].pendingCancelDepositRequest;
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingCancelRedeemRequest(IBaseVault vault_, address user) public view returns (bool isPending) {
        isPending = investments[vault_][user].pendingCancelRedeemRequest;
    }

    /// @inheritdoc IAsyncDepositManager
    function claimableCancelDepositRequest(IBaseVault vault_, address user) public view returns (uint256 assets) {
        assets = investments[vault_][user].claimableCancelDepositRequest;
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimableCancelRedeemRequest(IBaseVault vault_, address user) public view returns (uint256 shares) {
        shares = investments[vault_][user].claimableCancelRedeemRequest;
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(IBaseVault vault_, address from, address to, uint256 value) internal view returns (bool) {
        IShareToken share = IShareToken(vault_.share());
        return share.checkTransferRestriction(from, to, value);
    }

    function _assetToShareAmount(
        IBaseVault vault_,
        uint128 assets,
        uint256 priceAssetPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint128 shares) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        address shareToken = vault_.share();

        return PricingLib.assetToShareAmount(
            shareToken, vaultDetails.asset, vaultDetails.tokenId, assets, d18(priceAssetPerShare.toUint128()), rounding
        );
    }

    function _shareToAssetAmount(
        IBaseVault vault_,
        uint128 shares,
        uint256 priceAssetPerShare,
        MathLib.Rounding rounding
    ) internal view returns (uint128 assets) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        address shareToken = vault_.share();

        return PricingLib.shareToAssetAmount(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, d18(priceAssetPerShare.toUint128()), rounding
        );
    }

    function _calculatePriceAssetPerShare(IBaseVault vault_, uint128 shares, uint128 assets, MathLib.Rounding rounding)
        internal
        view
        returns (uint256 price)
    {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        address shareToken = vault_.share();

        return PricingLib.calculatePriceAssetPerShare(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets, rounding
        );
    }
}

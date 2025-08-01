// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseVault} from "./interfaces/IBaseVault.sol";
import {IRedeemManager} from "./interfaces/IVaultManagers.sol";
import {IDepositManager} from "./interfaces/IVaultManagers.sol";
import {IAsyncRedeemManager} from "./interfaces/IVaultManagers.sol";
import {IAsyncDepositManager} from "./interfaces/IVaultManagers.sol";
import {IBaseRequestManager} from "./interfaces/IBaseRequestManager.sol";
import {IAsyncVault, IAsyncRedeemVault} from "./interfaces/IAsyncVault.sol";
import {IAsyncRequestManager, AsyncInvestmentState} from "./interfaces/IVaultManagers.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IEscrow} from "../misc/interfaces/IEscrow.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IPoolEscrow} from "../common/interfaces/IPoolEscrow.sol";
import {ESCROW_HOOK_ID} from "../common/interfaces/ITransferHook.sol";
import {IRequestManager} from "../common/interfaces/IRequestManager.sol";
import {RequestMessageLib} from "../common/libraries/RequestMessageLib.sol";
import {RequestCallbackType, RequestCallbackMessageLib} from "../common/libraries/RequestCallbackMessageLib.sol";

import {IVault} from "../spoke/interfaces/IVault.sol";
import {IShareToken} from "../spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../spoke/interfaces/IBalanceSheet.sol";
import {ISpoke, VaultDetails} from "../spoke/interfaces/ISpoke.sol";
import {IVaultManager} from "../spoke/interfaces/IVaultManager.sol";

/// @title  Async Request Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncRequestManager is Auth, Recoverable, IAsyncRequestManager {
    using CastLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    IEscrow public immutable globalEscrow;

    ISpoke public spoke;
    IBalanceSheet public balanceSheet;

    mapping(IBaseVault vault => mapping(address investor => AsyncInvestmentState)) public investments;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => IBaseVault vault))) public vault;

    constructor(IEscrow globalEscrow_, address deployer) Auth(deployer) {
        globalEscrow = globalEscrow_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IVaultManager
    function addVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_, address asset_, uint256)
        public
        virtual
        auth
    {
        require(IBaseVault(address(vault_)).asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) == address(0), VaultAlreadyExists());

        vault[poolId][scId][assetId] = IBaseVault(address(vault_));

        emit AddVault(poolId, scId, assetId, vault_);
    }

    /// @inheritdoc IVaultManager
    function removeVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_, address asset_, uint256)
        public
        virtual
        auth
    {
        require(IBaseVault(address(vault_)).asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) == address(vault_), VaultDoesNotExist());

        delete vault[poolId][scId][assetId];

        emit RemoveVault(poolId, scId, assetId, vault_);
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
        _checkIsLinked(vault_);

        uint128 assets_ = assets.toUint128();
        require(assets_ != 0, ZeroAmountNotAllowed());
        require(_canTransfer(vault_, address(0), controller, convertToShares(vault_, assets_)), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());
        state.pendingDepositRequest += assets_;

        _sendRequest(vault_, RequestMessageLib.DepositRequest(controller.toBytes32(), assets_).serialize());

        return true;
    }

    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(
        IBaseVault vault_,
        uint256 shares,
        address controller,
        address owner,
        address sender_,
        bool transfer
    ) public auth returns (bool) {
        _checkIsLinked(vault_);

        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmountNotAllowed());
        require(
            _canTransfer(vault_, owner, ESCROW_HOOK_ID, shares)
                && _canTransfer(vault_, controller, ESCROW_HOOK_ID, shares),
            TransferNotAllowed()
        );

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());
        state.pendingRedeemRequest = state.pendingRedeemRequest + shares_;

        _sendRequest(vault_, RequestMessageLib.RedeemRequest(controller.toBytes32(), shares_).serialize());
        if (transfer) {
            balanceSheet.transferSharesFrom(
                vault_.poolId(), vault_.scId(), sender_, owner, address(globalEscrow), shares_
            );
        }

        return true;
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(IBaseVault vault_, address controller, address) public auth {
        _checkIsLinked(vault_);

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingDepositRequest > 0, NoPendingRequest());
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());
        state.pendingCancelDepositRequest = true;

        _sendRequest(vault_, RequestMessageLib.CancelDepositRequest(controller.toBytes32()).serialize());
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(IBaseVault vault_, address controller, address) public auth {
        _checkIsLinked(vault_);

        uint256 approximateSharesPayout = pendingRedeemRequest(vault_, controller);
        require(approximateSharesPayout > 0, NoPendingRequest());
        require(_canTransfer(vault_, address(0), controller, approximateSharesPayout), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());
        state.pendingCancelRedeemRequest = true;

        _sendRequest(vault_, RequestMessageLib.CancelRedeemRequest(controller.toBytes32()).serialize());
    }

    function _sendRequest(IBaseVault vault_, bytes memory payload) internal {
        spoke.request(vault_.poolId(), vault_.scId(), spoke.vaultDetails(vault_).assetId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway handlers
    //----------------------------------------------------------------------------------------------

    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external auth {
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
            revert IRequestManager.UnknownRequestCallbackType();
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

        globalEscrow.authTransferTo(asset, tokenId, address(poolEscrow(poolId)), assetAmount);
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
            _maxRedeem(vault_, user) + fulfilledShares,
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
        _checkIsLinked(vault_);
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
        _checkIsLinked(vault_);

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
        state.maxMint = state.maxMint - sharesUp;

        if (sharesDown > 0) {
            globalEscrow.authTransferTo(vault_.share(), 0, receiver, sharesDown);
        }
    }

    /// @inheritdoc IRedeemManager
    function redeem(IBaseVault vault_, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        _checkIsLinked(vault_);
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
        _checkIsLinked(vault_);

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
        state.maxWithdraw = state.maxWithdraw - assetsUp;

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
        _checkIsLinked(vault_);

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
        _checkIsLinked(vault_);

        AsyncInvestmentState storage state = investments[vault_][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;

        if (shares > 0) {
            globalEscrow.authTransferTo(vault_.share(), 0, receiver, shares);
        }
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address user) public view returns (uint256 assets) {
        assets = uint256(_maxDeposit(vault_, user));
        if (!_canTransfer(vault_, ESCROW_HOOK_ID, user, investments[vault_][user].maxMint)) return 0;
    }

    function _maxDeposit(IBaseVault vault_, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vault_][user];
        assets = _shareToAssetAmount(vault_, state.maxMint, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function maxMint(IBaseVault vault_, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vault_][user].maxMint);
        if (!_canTransfer(vault_, ESCROW_HOOK_ID, user, shares)) return 0;
    }

    /// @inheritdoc IRedeemManager
    function maxWithdraw(IBaseVault vault_, address user) public view returns (uint256 assets) {
        uint128 shares = _maxRedeem(vault_, user);
        if (!_canTransfer(vault_, user, address(0), shares)) return 0;
        assets = uint256(investments[vault_][user].maxWithdraw);
    }

    /// @inheritdoc IRedeemManager
    function maxRedeem(IBaseVault vault_, address user) public view returns (uint256 shares) {
        shares = _maxRedeem(vault_, user);
        if (!_canTransfer(vault_, user, address(0), shares)) return 0;
    }

    function _maxRedeem(IBaseVault vault_, address user) internal view returns (uint128 shares) {
        AsyncInvestmentState memory state = investments[vault_][user];
        shares = _assetToShareAmount(vault_, state.maxWithdraw, state.redeemPrice, MathLib.Rounding.Down);
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

    /// @inheritdoc IBaseRequestManager
    function convertToShares(IBaseVault vault_, uint256 assets) public view virtual returns (uint256 shares) {
        uint128 assets_ = assets.toUint128();
        VaultDetails memory vd = spoke.vaultDetails(vault_);
        (D18 pricePoolPerAsset, D18 pricePoolPerShare) =
            spoke.pricesPoolPer(vault_.poolId(), vault_.scId(), vd.assetId, false);

        return pricePoolPerShare.isZero()
            ? 0
            : PricingLib.assetToShareAmount(
                vault_.share(), vd.asset, vd.tokenId, assets_, pricePoolPerAsset, pricePoolPerShare, MathLib.Rounding.Down
            );
    }

    /// @inheritdoc IBaseRequestManager
    function convertToAssets(IBaseVault vault_, uint256 shares) public view virtual returns (uint256 assets) {
        uint128 shares_ = shares.toUint128();
        VaultDetails memory vd = spoke.vaultDetails(vault_);
        (D18 pricePoolPerAsset, D18 pricePoolPerShare) =
            spoke.pricesPoolPer(vault_.poolId(), vault_.scId(), vd.assetId, false);

        return pricePoolPerAsset.isZero()
            ? 0
            : PricingLib.shareToAssetAmount(
                vault_.share(), shares_, vd.asset, vd.tokenId, pricePoolPerShare, pricePoolPerAsset, MathLib.Rounding.Down
            );
    }

    /// @inheritdoc IBaseRequestManager
    function priceLastUpdated(IBaseVault vault_) public view virtual returns (uint64 lastUpdated) {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);

        (uint64 shareLastUpdated,,) = spoke.markersPricePoolPerShare(vault_.poolId(), vault_.scId());
        (uint64 assetLastUpdated,,) =
            spoke.markersPricePoolPerAsset(vault_.poolId(), vault_.scId(), vaultDetails.assetId);

        // Choose the latest update to be the marker
        lastUpdated = MathLib.max(shareLastUpdated, assetLastUpdated).toUint64();
    }

    /// @inheritdoc IBaseRequestManager
    function poolEscrow(PoolId poolId) public view returns (IPoolEscrow) {
        return balanceSheet.escrow(poolId);
    }

    /// @inheritdoc IVaultManager
    function vaultByAssetId(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (IVault) {
        return vault[poolId][scId][assetId];
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

    function _assetToShareAmount(IBaseVault vault_, uint128 assets, D18 priceAssetPerShare, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        address shareToken = vault_.share();

        return priceAssetPerShare.isZero()
            ? 0
            : PricingLib.assetToShareAmount(
                shareToken, vaultDetails.asset, vaultDetails.tokenId, assets, priceAssetPerShare, rounding
            );
    }

    function _shareToAssetAmount(IBaseVault vault_, uint128 shares, D18 priceAssetPerShare, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 assets)
    {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        address shareToken = vault_.share();

        return priceAssetPerShare.isZero()
            ? 0
            : PricingLib.shareToAssetAmount(
                shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, priceAssetPerShare, rounding
            );
    }

    function _calculatePriceAssetPerShare(IBaseVault vault_, uint128 shares, uint128 assets, MathLib.Rounding rounding)
        internal
        view
        returns (D18 price)
    {
        VaultDetails memory vaultDetails = spoke.vaultDetails(vault_);
        address shareToken = vault_.share();

        return shares == 0
            ? d18(0)
            : PricingLib.calculatePriceAssetPerShare(
                shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets, rounding
            );
    }

    /// @dev Here to reduce contract bytesize
    function _checkIsLinked(IVault vault_) internal view {
        require(spoke.isLinked(vault_), VaultNotLinked());
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseVault} from "./interfaces/IBaseVault.sol";
import {RequestMessageLib} from "./libraries/RequestMessageLib.sol";
import {IBaseRequestManager} from "./interfaces/IBaseRequestManager.sol";
import {IAsyncVault, IAsyncRedeemVault} from "./interfaces/IAsyncVault.sol";
import {RequestCallbackType, RequestCallbackMessageLib} from "./libraries/RequestCallbackMessageLib.sol";
import {
    IRedeemManager,
    IDepositManager,
    IAsyncRedeemManager,
    IAsyncDepositManager,
    IAsyncRequestManager,
    AsyncInvestmentState,
    REASON_DEPOSIT,
    REASON_REDEEM
} from "./interfaces/IVaultManagers.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IEscrow} from "../misc/interfaces/IEscrow.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {PricingLib} from "../core/libraries/PricingLib.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IPoolEscrow} from "../core/spoke/interfaces/IPoolEscrow.sol";
import {ISpokeRequestManager} from "../core/spoke/interfaces/ISpokeRequestManager.sol";
import {VaultDetails, ISpokeRegistry} from "../core/spoke/interfaces/ISpokeRegistry.sol";

import {IShareToken} from "../token/interfaces/IShareToken.sol";
import {ESCROW_HOOK_ID} from "../token/interfaces/ITransferHook.sol";
import {ISubsidyManager} from "../utils/interfaces/ISubsidyManager.sol";

/// @title  Async Request Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncRequestManager is Auth, IAsyncRequestManager {
    using CastLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    ISpoke public spoke;
    ISpokeRegistry public spokeRegistry;
    ISubsidyManager public subsidyManager;

    mapping(IBaseVault vault => mapping(address investor => AsyncInvestmentState)) public investments;

    constructor(ISubsidyManager subsidyManager_, address deployer) Auth(deployer) {
        subsidyManager = subsidyManager_;
    }

    receive() external payable {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else if (what == "subsidyManager") subsidyManager = ISubsidyManager(data);
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
        _checkIsLinked(vault_);

        uint128 assets_ = assets.toUint128();
        require(assets_ != 0, ZeroAmountNotAllowed());
        require(_canTransfer(vault_, address(0), controller, convertToShares(vault_, assets_)), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(!state.pendingCancelDepositRequest, CancellationIsPending());
        state.pendingDepositRequest = state.pendingDepositRequest + assets_;

        _sendRequest(vault_, RequestMessageLib.DepositRequest(controller.toBytes32(), assets_).serialize());

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));
        PoolId poolId = vaultDetails.poolId;
        ShareClassId scId = vaultDetails.scId;

        // The vault transfers the pending assets into the pool escrow right after this call. Note them
        // into the holding and immediately reserve them: the two queued updates cancel out, so the pending
        // deposit is not hub-accounted until approval and does not consume escrow withdrawal headroom.
        spoke.noteDeposit(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, assets_);
        spoke.reserve(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, assets_, address(this), REASON_DEPOSIT);

        return true;
    }

    /// @inheritdoc IAsyncRedeemManager
    /// @dev The `transfer` flag is deprecated and ignored: shares are always transferred to the pool escrow.
    function requestRedeem(
        IBaseVault vault_,
        uint256 shares,
        address controller,
        address owner,
        address sender_,
        bool /* transfer */
    )
        public
        auth
        returns (bool)
    {
        _checkIsLinked(vault_);

        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmountNotAllowed());
        require(
            _canTransfer(vault_, owner, ESCROW_HOOK_ID, shares)
                && _canTransfer(vault_, controller, ESCROW_HOOK_ID, shares),
            TransferNotAllowed()
        );

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(!state.pendingCancelRedeemRequest, CancellationIsPending());
        state.pendingRedeemRequest = state.pendingRedeemRequest + shares_;

        _sendRequest(vault_, RequestMessageLib.RedeemRequest(controller.toBytes32(), shares_).serialize());

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));
        PoolId poolId = vaultDetails.poolId;
        spoke.transferSharesFrom(poolId, vaultDetails.scId, sender_, owner, address(spoke.escrow(poolId)), shares_);

        return true;
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(IBaseVault vault_, address controller, address) public auth {
        _checkIsLinked(vault_);

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingDepositRequest > 0, NoPendingRequest());
        require(!state.pendingCancelDepositRequest, CancellationIsPending());
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
        require(!state.pendingCancelRedeemRequest, CancellationIsPending());
        state.pendingCancelRedeemRequest = true;

        _sendRequest(vault_, RequestMessageLib.CancelRedeemRequest(controller.toBytes32()).serialize());
    }

    function _sendRequest(IBaseVault vault_, bytes memory payload) internal {
        address refund;
        uint256 payment;

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));
        PoolId poolId = vaultDetails.poolId;
        AssetId assetId = vaultDetails.assetId;

        if (!spoke.gateway().isBatching() && poolId.centrifugeId() != assetId.centrifugeId()) {
            (refund, payment) = subsidyManager.withdrawAll(poolId, address(this));
        }

        // It use all funds for the message, and the rest is refunded again to the RefundEscrow
        spoke.request{value: payment}(poolId, vaultDetails.scId, assetId, payload, 0, true, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway handlers
    //----------------------------------------------------------------------------------------------

    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external auth {
        uint8 kind = uint8(RequestCallbackMessageLib.requestCallbackType(payload));

        if (kind == uint8(RequestCallbackType.ApprovedDeposits)) {
            RequestCallbackMessageLib.ApprovedDeposits memory m = payload.deserializeApprovedDeposits();
            approvedDeposits(poolId, scId, assetId, m.assetAmount);
        } else if (kind == uint8(RequestCallbackType.IssuedShares)) {
            RequestCallbackMessageLib.IssuedShares memory m = payload.deserializeIssuedShares();
            issuedShares(poolId, scId, m.shareAmount);
        } else if (kind == uint8(RequestCallbackType.RevokedShares)) {
            RequestCallbackMessageLib.RevokedShares memory m = payload.deserializeRevokedShares();
            revokedShares(poolId, scId, assetId, m.assetAmount, m.shareAmount);
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
            revert ISpokeRequestManager.UnknownRequestCallbackType();
        }
    }

    function approvedDeposits(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount) internal {
        (address asset, uint256 tokenId) = spokeRegistry.idToAsset(assetId, true);

        // Release the request-time reservation: the assets enter the hub-accounted holding, valued
        // hub-side when the queue is submitted.
        spoke.unreserve(poolId, scId, asset, tokenId, assetAmount, address(this), REASON_DEPOSIT);
    }

    function issuedShares(PoolId poolId, ShareClassId scId, uint128 shareAmount) internal {
        // Shares parked in the pool escrow for claiming carry no holding accounting.
        spoke.issue(poolId, scId, address(spoke.escrow(poolId)), shareAmount);
    }

    function revokedShares(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount, uint128 shareAmount)
        internal
    {
        (address asset, uint256 tokenId) = spokeRegistry.idToAsset(assetId, true);

        // Earmark the redemption payout: reserving removes the assets from the hub-accounted holding
        // atomically with the share burn, preventing NAV desync. The escrow update is deferred to claim.
        spoke.reserve(poolId, scId, asset, tokenId, assetAmount, address(this), REASON_REDEEM);

        address poolEscrow_ = address(spoke.escrow(poolId));
        spoke.transferSharesFrom(poolId, scId, poolEscrow_, poolEscrow_, address(this), shareAmount);

        SafeTransferLib.safeApprove(address(spokeRegistry.shareToken(poolId, scId)), address(spoke), shareAmount);
        spoke.revoke(poolId, scId, shareAmount);
    }

    function fulfillDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssets,
        uint128 fulfilledShares,
        uint128 cancelledAssets
    ) internal {
        IAsyncVault vault_ = IAsyncVault(address(_requestVault(poolId, scId, assetId)));
        AsyncInvestmentState storage state = investments[vault_][user];

        require(state.pendingDepositRequest != 0, NoPendingRequest());
        if (cancelledAssets > 0) {
            require(state.pendingCancelDepositRequest, NoPendingRequest());
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

    function fulfillRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssets,
        uint128 fulfilledShares,
        uint128 cancelledShares
    ) internal {
        IAsyncRedeemVault vault_ = IAsyncRedeemVault(address(_requestVault(poolId, scId, assetId)));

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

        uint128 assets_ = assets.toUint128();
        uint128 sharesUp = _assetToShareAmount(vault_, assets_, state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _assetToShareAmount(vault_, assets_, state.depositPrice, MathLib.Rounding.Down);
        shares = uint256(sharesDown);
        _processDeposit(state, sharesUp, sharesDown, vault_, receiver, controller);
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
        _processDeposit(state, shares_, shares_, vault_, receiver, controller);
    }

    function _processDeposit(
        AsyncInvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        IBaseVault vault_,
        address receiver,
        address controller
    ) internal {
        require(sharesUp <= state.maxMint, ExceedsDepositLimits());
        state.maxMint = state.maxMint - sharesUp;

        if (sharesDown > 0) {
            VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));

            // The share transfer checks the receiver, not the controller. Mirrors {maxMint}.
            require(_canTransfer(vault_, _escrow(vault_), controller, sharesDown), TransferNotAllowed());

            spoke.withdrawShares(vaultDetails.poolId, vaultDetails.scId, receiver, sharesDown);
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

        uint128 shares_ = shares.toUint128();
        uint128 assetsUp = _shareToAssetAmount(vault_, shares_, state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _shareToAssetAmount(vault_, shares_, state.redeemPrice, MathLib.Rounding.Down);
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
            VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));

            // The holding decrease was already queued when the payout was reserved in revokedShares.
            spoke.withdrawReserved(
                vaultDetails.poolId,
                vaultDetails.scId,
                vaultDetails.asset,
                vaultDetails.tokenId,
                receiver,
                assetsDown,
                address(this),
                REASON_REDEEM
            );
        }
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

        if (controller != receiver) {
            require(_canTransfer(vault_, controller, receiver, convertToShares(vault_, assets)), TransferNotAllowed());
        }
        require(_canTransfer(vault_, receiver, address(0), convertToShares(vault_, assets)), TransferNotAllowed());

        if (assets > 0) {
            VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));

            // The pending deposit was never hub-accounted (deposit and reserve cancelled out at request
            // time), so the cancellation refund claims the reserved assets without queueing an update.
            spoke.withdrawReserved(
                vaultDetails.poolId,
                vaultDetails.scId,
                vaultDetails.asset,
                vaultDetails.tokenId,
                receiver,
                assets.toUint128(),
                address(this),
                REASON_DEPOSIT
            );
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
            VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));

            // Same reasoning as {_processDeposit}.
            require(_canTransfer(vault_, _escrow(vault_), controller, shares), TransferNotAllowed());

            spoke.withdrawShares(vaultDetails.poolId, vaultDetails.scId, receiver, shares.toUint128());
        }
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address user) public view returns (uint256 assets) {
        assets = _maxDeposit(vault_, user);
        if (!_canTransfer(vault_, _escrow(vault_), user, investments[vault_][user].maxMint)) {
            return 0;
        }
    }

    function _maxDeposit(IBaseVault vault_, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vault_][user];
        assets = _shareToAssetAmount(vault_, state.maxMint, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function maxMint(IBaseVault vault_, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vault_][user].maxMint);
        if (!_canTransfer(vault_, _escrow(vault_), user, uint256(investments[vault_][user].maxMint))) return 0;
    }

    /// @inheritdoc IRedeemManager
    function maxWithdraw(IBaseVault vault_, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vault_, user, address(0), _maxRedeem(vault_, user))) return 0;
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
        return uint256(investments[vault_][user].pendingDepositRequest);
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
        if (!_canTransfer(vault_, user, address(0), convertToShares(vault_, assets))) return 0;
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimableCancelRedeemRequest(IBaseVault vault_, address user) public view returns (uint256 shares) {
        shares = investments[vault_][user].claimableCancelRedeemRequest;
        if (!_canTransfer(vault_, _escrow(vault_), user, shares)) return 0;
    }

    /// @inheritdoc IBaseRequestManager
    function convertToShares(IBaseVault vault_, uint256 assets) public view virtual returns (uint256 shares) {
        uint128 assets_ = assets.toUint128();
        VaultDetails memory vd = spokeRegistry.vaultDetails(address(vault_));
        require(vd.asset != address(0), ISpokeRegistry.UnknownVault());
        D18 pricePoolPerAsset = spokeRegistry.pricePoolPerAsset(vd.poolId, vd.scId, vd.assetId, false);
        D18 pricePoolPerShare = spokeRegistry.pricePoolPerShare(vd.poolId, vd.scId, false);

        return pricePoolPerShare.isZero()
            ? 0
            : PricingLib.assetToShareAmount(
                vault_.share(),
                vd.asset,
                vd.tokenId,
                assets_,
                pricePoolPerAsset,
                pricePoolPerShare,
                MathLib.Rounding.Down
            );
    }

    /// @inheritdoc IBaseRequestManager
    function convertToAssets(IBaseVault vault_, uint256 shares) public view virtual returns (uint256 assets) {
        uint128 shares_ = shares.toUint128();
        VaultDetails memory vd = spokeRegistry.vaultDetails(address(vault_));
        require(vd.asset != address(0), ISpokeRegistry.UnknownVault());
        D18 pricePoolPerAsset = spokeRegistry.pricePoolPerAsset(vd.poolId, vd.scId, vd.assetId, false);
        D18 pricePoolPerShare = spokeRegistry.pricePoolPerShare(vd.poolId, vd.scId, false);

        return pricePoolPerAsset.isZero()
            ? 0
            : PricingLib.shareToAssetAmount(
                vault_.share(),
                shares_,
                vd.asset,
                vd.tokenId,
                pricePoolPerShare,
                pricePoolPerAsset,
                MathLib.Rounding.Down
            );
    }

    /// @inheritdoc IBaseRequestManager
    function priceLastUpdated(IBaseVault vault_) public view virtual returns (uint64 lastUpdated) {
        VaultDetails memory vd = spokeRegistry.vaultDetails(address(vault_));
        require(vd.asset != address(0), ISpokeRegistry.UnknownVault());

        uint64 shareLastUpdated = spokeRegistry.pricePoolPerShareComputedAt(vd.poolId, vd.scId);
        uint64 assetLastUpdated = spokeRegistry.pricePoolPerAssetComputedAt(vd.poolId, vd.scId, vd.assetId);

        // Choose the latest update to be the marker
        lastUpdated = MathLib.max(shareLastUpdated, assetLastUpdated).toUint64();
    }

    /// @inheritdoc IBaseRequestManager
    function poolEscrow(PoolId poolId) public view returns (IPoolEscrow) {
        return spoke.escrow(poolId);
    }

    /// @inheritdoc IBaseRequestManager
    function globalEscrow() external view override returns (IEscrow) {
        // NOTE: Inlining vault() instead of caching on purpose to save critical 6 bytes of deploy size
        require(spokeRegistry.isLinked(msg.sender), NotAVault());

        return IEscrow(_escrow(IBaseVault(msg.sender)));
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(IBaseVault vault_, address from, address to, uint256 value) internal view returns (bool) {
        return IShareToken(vault_.share()).checkTransferRestriction(from, to, value);
    }

    function _assetToShareAmount(IBaseVault vault_, uint128 assets, D18 priceAssetPerShare, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));
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
        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));
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
        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault_));
        address shareToken = vault_.share();

        return shares == 0
            ? d18(0)
            : PricingLib.calculatePriceAssetPerShare(
                shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets, rounding
            );
    }

    /// @dev Here to reduce contract bytesize
    function _checkIsLinked(IBaseVault vault_) internal view {
        require(spokeRegistry.isLinked(address(vault_)), VaultNotLinked());
    }

    /// @dev Here to reduce contract bytesize
    function _escrow(IBaseVault vault_) internal view returns (address) {
        return address(spoke.escrow(spokeRegistry.vaultDetails(address(vault_)).poolId));
    }

    /// @dev Resolves a fulfillment callback (keyed by the tuple) back to its vault via the share token's
    ///      ERC-7575 pointer, which the registrar keeps aimed at the currently-linked vault for `assetId`.
    function _requestVault(PoolId poolId, ShareClassId scId, AssetId assetId)
        internal
        view
        returns (IBaseVault vault_)
    {
        (address asset,) = spokeRegistry.idToAsset(assetId, true);
        vault_ = IBaseVault(IShareToken(address(spokeRegistry.shareToken(poolId, scId))).vault(asset));
    }
}

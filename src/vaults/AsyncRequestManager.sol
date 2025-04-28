// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IInvestmentManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IAsyncRequestManager, AsyncInvestmentState} from "src/vaults/interfaces/investments/IAsyncRequestManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IAsyncDepositManager} from "src/vaults/interfaces/investments/IAsyncDepositManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncVault, IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {ESCROW_HOOK_ID} from "src/common/interfaces/IHook.sol";

/// @title  Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncRequestManager is BaseInvestmentManager, IAsyncRequestManager {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    IVaultMessageSender public sender;
    IBalanceSheet public balanceSheet;

    mapping(IBaseVault vault => mapping(address investor => AsyncInvestmentState)) public investments;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => IAsyncVault vault))) public vault;

    constructor(IEscrow globalEscrow_, address root_, address deployer)
        BaseInvestmentManager(globalEscrow_, root_, deployer)
    {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IVaultManager
    /// @dev vault_ Must be an IAsyncVault
    function addVault(PoolId poolId, ShareClassId scId, IBaseVault vault_, address asset_, AssetId assetId)
        public
        auth
    {
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) == address(0), VaultAlreadyExists());

        vault[poolId][scId][assetId] = IAsyncVault(address(vault_));
        IAuth(token).rely(address(vault_));
        IShareToken(token).updateVault(vault_.asset(), address(vault_));
        rely(address(vault_));
    }

    /// @inheritdoc IVaultManager
    function removeVault(PoolId poolId, ShareClassId scId, IBaseVault vault_, address asset_, AssetId assetId)
        public
        auth
    {
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(address(vault[poolId][scId][assetId]) != address(0), VaultDoesNotExist());

        delete vault[poolId][scId][assetId];

        IAuth(token).deny(address(vault_));
        IShareToken(token).updateVault(vault_.asset(), address(0));
        deny(address(vault_));
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

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        require(poolManager.isLinked(poolId, scId, vaultDetails.asset, vault_), AssetNotAllowed());

        require(_canTransfer(vault_, address(0), controller, convertToShares(vault_, assets_)), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());

        state.pendingDepositRequest += assets_;
        sender.sendDepositRequest(poolId, scId, controller.toBytes32(), vaultDetails.assetId, assets_);

        return true;
    }

    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(IBaseVault vault_, uint256 shares, address controller, address owner, address)
        public
        auth
        returns (bool)
    {
        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmountNotAllowed());

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        require(poolManager.isLinked(poolId, scId, vaultDetails.asset, vault_), AssetNotAllowed());

        require(
            _canTransfer(vault_, owner, ESCROW_HOOK_ID, shares)
                && _canTransfer(vault_, controller, ESCROW_HOOK_ID, shares),
            TransferNotAllowed()
        );

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares_;
        sender.sendRedeemRequest(poolId, scId, controller.toBytes32(), vaultDetails.assetId, shares_);

        return true;
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(IBaseVault vault_, address controller, address) public auth {
        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingDepositRequest > 0, NoPendingRequest());
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());
        state.pendingCancelDepositRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);

        sender.sendCancelDepositRequest(vault_.poolId(), vault_.scId(), controller.toBytes32(), vaultDetails.assetId);
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(IBaseVault vault_, address controller, address) public auth {
        uint256 approximateSharesPayout = pendingRedeemRequest(vault_, controller);
        require(approximateSharesPayout > 0, NoPendingRequest());
        require(_canTransfer(vault_, address(0), controller, approximateSharesPayout), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());
        state.pendingCancelRedeemRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);

        sender.sendCancelRedeemRequest(vault_.poolId(), vault_.scId(), controller.toBytes32(), vaultDetails.assetId);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function approvedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);

        // Note deposit and transfer from global escrow into the pool escrow,
        // to make assets available for managers of the balance sheet
        balanceSheet.overridePricePoolPerAsset(poolId, scId, assetId, pricePoolPerAsset);
        balanceSheet.noteDeposit(poolId, scId, asset, tokenId, address(globalEscrow), assetAmount);

        address poolEscrow = address(poolEscrowProvider.escrow(poolId));
        globalEscrow.authTransferTo(asset, tokenId, poolEscrow, assetAmount);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function issuedShares(PoolId poolId, ShareClassId scId, uint128 shareAmount, D18 pricePoolPerShare) external auth {
        balanceSheet.overridePricePoolPerShare(poolId, scId, pricePoolPerShare);
        balanceSheet.issue(poolId, scId, address(globalEscrow), shareAmount);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function revokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external auth {
        // Lock assets to ensure they are not withdrawn and are available for the redeeming user
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        poolEscrowProvider.escrow(poolId).reserveIncrease(scId, asset, tokenId, assetAmount);

        balanceSheet.overridePricePoolPerShare(poolId, scId, pricePoolPerShare);
        balanceSheet.revoke(poolId, scId, address(globalEscrow), shareAmount);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        IAsyncVault vault_ = vault[poolId][scId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingDepositRequest != 0, NoPendingRequest());
        state.depositPrice = _calculatePriceAssetPerShare(
            vault_, state.maxMint + shares, _maxDeposit(vault_, user) + assets, MathLib.Rounding.Down
        );
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        vault_.onDepositClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        IAsyncVault vault_ = vault[poolId][scId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingRedeemRequest != 0, NoPendingRequest());

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice = _calculatePriceAssetPerShare(
            vault_, ((maxRedeem(vault_, user)) + shares).toUint128(), state.maxWithdraw + assets, MathLib.Rounding.Down
        );
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        vault_.onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 assets,
        uint128 fulfillment
    ) public auth {
        IAsyncVault vault_ = vault[poolId][scId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelDepositRequest == true, NoPendingRequest());

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        vault_.onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillCancelRedeemRequest(PoolId poolId, ShareClassId scId, address user, AssetId assetId, uint128 shares)
        public
        auth
    {
        IAsyncVault vault_ = vault[poolId][scId][assetId];
        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelRedeemRequest == true, NoPendingRequest());

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        vault_.onCancelRedeemClaimable(user, shares);
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
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);

        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        poolEscrowProvider.escrow(poolId).reserveDecrease(scId, vaultDetails.asset, vaultDetails.tokenId, assets);
        balanceSheet.withdraw(poolId, scId, vaultDetails.asset, vaultDetails.tokenId, receiver, assets);
    }

    //----------------------------------------------------------------------------------------------
    // Cancelation claim handlers
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
            VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
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

    /// @inheritdoc IVaultManager
    function vaultByAssetId(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (IBaseVault) {
        return vault[poolId][scId][assetId];
    }

    /// @inheritdoc IVaultManager
    function vaultKind(IBaseVault) public pure returns (VaultKind, address) {
        return (VaultKind.Async, address(0));
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
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
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
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
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
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        address shareToken = vault_.share();

        return PricingLib.calculatePriceAssetPerShare(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets, rounding
        );
    }
}

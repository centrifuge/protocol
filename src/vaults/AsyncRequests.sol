// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {D18} from "src/misc/types/D18.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IInvestmentManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IAsyncRequests, AsyncInvestmentState} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IAsyncDepositManager} from "src/vaults/interfaces/investments/IAsyncDepositManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncVault, IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {VaultPricingLib} from "src/vaults/libraries/VaultPricingLib.sol";
import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {ESCROW_HOOK_ID} from "src/vaults/interfaces/token/IHook.sol";

/// @title  Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncRequests is BaseInvestmentManager, IAsyncRequests {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    IVaultMessageSender public sender;
    IBalanceSheet public balanceSheet;

    mapping(IBaseVault vault => mapping(address investor => AsyncInvestmentState)) public investments;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => IAsyncVault vault))) public vault;

    constructor(address root_, address deployer) BaseInvestmentManager(root_, deployer) {}

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    // --- IVaultManager ---
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

    // --- Async investment handlers ---
    /// @inheritdoc IAsyncDepositManager
    function requestDeposit(IBaseVault vault_, uint256 assets, address controller, address, address)
        public
        auth
        returns (bool)
    {
        uint128 _assets = assets.toUint128();
        require(_assets != 0, ZeroAmountNotAllowed());

        return _processDepositRequest(vault_, _assets, controller);
    }

    /// @dev Necessary because of stack-too-deep
    function _processDepositRequest(IBaseVault vault_, uint128 assets, address controller) internal returns (bool) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        PoolId poolId = vault_.poolId();
        ShareClassId scId = vault_.scId();

        require(poolManager.isLinked(poolId, scId, vaultDetails.asset, vault_), AssetNotAllowed());

        require(_canTransfer(vault_, address(0), controller, convertToShares(vault_, assets)), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());

        state.pendingDepositRequest += assets;
        sender.sendDepositRequest(poolId, scId, controller.toBytes32(), vaultDetails.assetId, assets);

        return true;
    }

    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(IBaseVault vault_, uint256 shares, address controller, address owner, address)
        public
        auth
        returns (bool)
    {
        uint128 _shares = shares.toUint128();
        require(_shares != 0, ZeroAmountNotAllowed());

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(poolManager.isLinked(vault_.poolId(), vault_.scId(), vault_.asset(), vault_), AssetNotAllowed());

        require(
            _canTransfer(vault_, owner, ESCROW_HOOK_ID, shares)
                && _canTransfer(vault_, controller, ESCROW_HOOK_ID, shares),
            TransferNotAllowed()
        );

        return _processRedeemRequest(vault_, _shares, controller, source, false);
    }

    /// @dev    triggered indicates if the the _processRedeemRequest call was triggered from centrifugeChain
    function _processRedeemRequest(IBaseVault vault_, uint128 shares, address controller, address, bool triggered)
        internal
        returns (bool)
    {
        AsyncInvestmentState storage state = investments[vault_][controller];
        require(state.pendingCancelRedeemRequest != true || triggered, CancellationIsPending());

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);

        sender.sendRedeemRequest(vault_.poolId(), vault_.scId(), controller.toBytes32(), vaultDetails.assetId, shares);

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

    // -- Gateway handlers --
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
        state.depositPrice = _calculatePrice(vault_, state.maxMint + shares, _maxDeposit(vault_, user) + assets);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint to escrow. Recipient can claim by calling deposit / mint
        IShareToken shareToken = IShareToken(vault_.share());
        shareToken.mint(address(poolEscrowProvider.escrow(poolId)), shares);

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
        state.redeemPrice =
            _calculatePrice(vault_, ((maxRedeem(vault_, user)) + shares).toUint128(), state.maxWithdraw + assets);
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed share class tokens from escrow
        IShareToken shareToken = IShareToken(vault_.share());
        shareToken.burn(address(poolEscrowProvider.escrow(poolId)), shares);

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

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function triggerRedeemRequest(PoolId poolId, ShareClassId scId, address user, AssetId assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, ShareTokenAmountIsZero());
        IAsyncVault vault_ = vault[poolId][scId][assetId];

        // If there's any unclaimed deposits, claim those first
        AsyncInvestmentState storage state = investments[vault_][user];
        uint128 tokensToTransfer = shares;
        if (state.maxMint >= shares) {
            // The full redeem request is covered by the claimable amount
            tokensToTransfer = 0;
            state.maxMint = state.maxMint - shares;
        } else if (state.maxMint != 0) {
            // The redeem request is only partially covered by the claimable amount
            tokensToTransfer = shares - state.maxMint;
            state.maxMint = 0;
        }

        require(_processRedeemRequest(vault_, shares, user, msg.sender, true), FailedRedeemRequest());

        // Transfer the token token amount that was not covered by tokens still in escrow for claims,
        // from user to escrow (lock share class tokens in escrow)
        if (tokensToTransfer != 0) {
            require(
                IShareToken(vault_.share()).authTransferFrom(
                    user, user, address(poolEscrowProvider.escrow(poolId)), tokensToTransfer
                ),
                ShareTokenTransferFailed()
            );
        }

        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        emit TriggerRedeemRequest(poolId.raw(), scId.raw(), user, asset, tokenId, shares);
        vault_.onRedeemRequest(user, user, shares);
    }

    // --- Sync investment handlers ---
    /// @inheritdoc IDepositManager
    function deposit(IBaseVault vault_, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vault_, controller), ExceedsMaxDeposit());

        AsyncInvestmentState storage state = investments[vault_][controller];

        uint128 sharesUp = _calculateShares(vault_, assets.toUint128(), state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _calculateShares(vault_, assets.toUint128(), state.depositPrice, MathLib.Rounding.Down);
        _processDeposit(state, sharesUp, sharesDown, vault_, receiver);
        shares = uint256(sharesDown);
    }

    /// @inheritdoc IDepositManager
    function mint(IBaseVault vault_, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        AsyncInvestmentState storage state = investments[vault_][controller];
        uint128 shares_ = shares.toUint128();
        _processDeposit(state, shares_, shares_, vault_, receiver);

        assets = uint256(_calculateAssets(vault_, shares_, state.depositPrice, MathLib.Rounding.Down));
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
            require(
                IERC20(vault_.share()).transferFrom(
                    address(poolEscrowProvider.escrow(vault_.poolId())), receiver, sharesDown
                ),
                ShareTokenTransferFailed()
            );
        }
    }

    // --- Redeem Manager ---
    /// @inheritdoc IRedeemManager
    function redeem(IBaseVault vault_, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vault_, controller), ExceedsMaxRedeem());

        AsyncInvestmentState storage state = investments[vault_][controller];

        uint128 assetsUp = _calculateAssets(vault_, shares.toUint128(), state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _calculateAssets(vault_, shares.toUint128(), state.redeemPrice, MathLib.Rounding.Down);
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

        shares = uint256(_calculateShares(vault_, assets_, state.redeemPrice, MathLib.Rounding.Down));
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

        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, vaultDetails.assetId, true);
        IPoolEscrow(address(poolEscrowProvider.escrow(poolId))).reserveDecrease(
            scId, vaultDetails.asset, vaultDetails.tokenId, assets
        );

        balanceSheet.withdraw(
            poolId, scId, vaultDetails.asset, vaultDetails.tokenId, receiver, assets, pricePoolPerAsset
        );
    }

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

            address escrow = address(poolEscrowProvider.escrow(vault_.poolId()));
            if (vaultDetails.tokenId == 0) {
                SafeTransferLib.safeTransferFrom(vaultDetails.asset, escrow, receiver, assets);
            } else {
                IERC6909(vaultDetails.asset).transferFrom(escrow, receiver, vaultDetails.tokenId, assets);
            }
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
            require(
                IERC20(vault_.share()).transferFrom(
                    address(poolEscrowProvider.escrow(vault_.poolId())), receiver, shares
                ),
                ShareTokenTransferFailed()
            );
        }
    }

    // --- View functions ---
    /// @inheritdoc IDepositManager
    function maxDeposit(IBaseVault vault_, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vault_, ESCROW_HOOK_ID, user, 0)) {
            return 0;
        }
        assets = uint256(_maxDeposit(vault_, user));
    }

    function _maxDeposit(IBaseVault vault_, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vault_][user];

        assets = _calculateAssets(vault_, state.maxMint, state.depositPrice, MathLib.Rounding.Down);
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

        shares = uint256(_calculateShares(vault_, state.maxWithdraw, state.redeemPrice, MathLib.Rounding.Down));
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

    // --- Helpers ---
    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(IBaseVault vault_, address from, address to, uint256 value) internal view returns (bool) {
        IShareToken share = IShareToken(vault_.share());
        return share.checkTransferRestriction(from, to, value);
    }

    function _calculateShares(IBaseVault vault_, uint128 assets, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        address shareToken = vault_.share();

        return VaultPricingLib.calculateShares(
            shareToken, vaultDetails.asset, vaultDetails.tokenId, assets, price, rounding
        );
    }

    function _calculateAssets(IBaseVault vault_, uint128 shares, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 assets)
    {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        address shareToken = vault_.share();

        return VaultPricingLib.calculateAssets(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, price, rounding
        );
    }

    function _calculatePrice(IBaseVault vault_, uint128 shares, uint128 assets) internal view returns (uint256 price) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault_);
        address shareToken = vault_.share();

        return VaultPricingLib.calculatePrice(shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets);
    }
}

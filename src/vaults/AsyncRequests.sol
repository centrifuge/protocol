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
import {ISharePriceProvider, Prices} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncVault, IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
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
    ISharePriceProvider public sharePriceProvider;

    mapping(address vault => mapping(address investor => AsyncInvestmentState)) public investments;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(uint128 assetId => address vault))) public vault;

    constructor(address root_, address deployer) BaseInvestmentManager(root_, deployer) {}

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheet(data);
        else if (what == "sharePriceProvider") sharePriceProvider = ISharePriceProvider(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(vault[poolId][scId][assetId] == address(0), VaultAlreadyExists());

        vault[poolId][scId][assetId] = vaultAddr;
        IAuth(token).rely(vaultAddr);
        IShareToken(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, AssetMismatch());
        require(vault[poolId][scId][assetId] != address(0), VaultDoesNotExist());

        delete vault[poolId][scId][assetId];

        IAuth(token).deny(vaultAddr);
        IShareToken(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);
    }

    // --- Async investment handlers ---
    /// @inheritdoc IAsyncDepositManager
    function requestDeposit(address vaultAddr, uint256 assets, address controller, address, address)
        public
        auth
        returns (bool)
    {
        uint128 _assets = assets.toUint128();
        require(_assets != 0, ZeroAmountNotAllowed());

        return _processDepositRequest(vaultAddr, _assets, controller);
    }

    /// @dev Necessary because of stack-too-deep
    function _processDepositRequest(address vaultAddr, uint128 assets, address controller) internal returns (bool) {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        uint64 poolId = vault_.poolId();
        bytes16 scId = vault_.scId();

        require(poolManager.isLinked(poolId, scId, vaultDetails.asset, vaultAddr), AssetNotAllowed());

        require(
            _canTransfer(vaultAddr, address(0), controller, convertToShares(vaultAddr, assets)), TransferNotAllowed()
        );

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());

        state.pendingDepositRequest += assets;
        sender.sendDepositRequest(
            PoolId.wrap(poolId), ShareClassId.wrap(scId), controller.toBytes32(), vaultDetails.assetId, assets
        );

        return true;
    }

    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(address vaultAddr, uint256 shares, address controller, address owner, address source)
        public
        auth
        returns (bool)
    {
        uint128 _shares = shares.toUint128();
        require(_shares != 0, ZeroAmountNotAllowed());
        IAsyncVault vault_ = IAsyncVault(vaultAddr);

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(poolManager.isLinked(vault_.poolId(), vault_.scId(), vault_.asset(), vaultAddr), AssetNotAllowed());

        require(
            _canTransfer(vaultAddr, owner, ESCROW_HOOK_ID, shares)
                && _canTransfer(vaultAddr, controller, ESCROW_HOOK_ID, shares),
            TransferNotAllowed()
        );

        return _processRedeemRequest(vaultAddr, _shares, controller, source, false);
    }

    /// @dev    triggered indicates if the the _processRedeemRequest call was triggered from centrifugeChain
    function _processRedeemRequest(address vaultAddr, uint128 shares, address controller, address, bool triggered)
        internal
        returns (bool)
    {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true || triggered, CancellationIsPending());

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendRedeemRequest(
            PoolId.wrap(vault_.poolId()),
            ShareClassId.wrap(vault_.scId()),
            controller.toBytes32(),
            vaultDetails.assetId,
            shares
        );

        return true;
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(address vaultAddr, address controller, address) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingDepositRequest > 0, NoPendingRequest());
        require(state.pendingCancelDepositRequest != true, CancellationIsPending());
        state.pendingCancelDepositRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendCancelDepositRequest(
            PoolId.wrap(vault_.poolId()), ShareClassId.wrap(vault_.scId()), controller.toBytes32(), vaultDetails.assetId
        );
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(address vaultAddr, address controller, address) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        uint256 approximateSharesPayout = pendingRedeemRequest(vaultAddr, controller);
        require(approximateSharesPayout > 0, NoPendingRequest());
        require(_canTransfer(vaultAddr, address(0), controller, approximateSharesPayout), TransferNotAllowed());

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true, CancellationIsPending());
        state.pendingCancelRedeemRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendCancelRedeemRequest(
            PoolId.wrap(vault_.poolId()), ShareClassId.wrap(vault_.scId()), controller.toBytes32(), vaultDetails.assetId
        );
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
        address vault_ = vault[poolId.raw()][scId.raw()][assetId.raw()];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingDepositRequest != 0, NoPendingRequest());
        state.depositPrice = _calculatePrice(vault_, state.maxMint + shares, _maxDeposit(vault_, user) + assets);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint to escrow. Recipient can claim by calling deposit / mint
        IShareToken shareToken = IShareToken(IAsyncVault(vault_).share());
        shareToken.mint(address(poolEscrowProvider.escrow(poolId.raw())), shares);

        IAsyncVault(vault_).onDepositClaimable(user, assets, shares);
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
        address vault_ = vault[poolId.raw()][scId.raw()][assetId.raw()];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingRedeemRequest != 0, NoPendingRequest());

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice =
            _calculatePrice(vault_, ((maxRedeem(vault_, user)) + shares).toUint128(), state.maxWithdraw + assets);
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed share class tokens from escrow
        IShareToken shareToken = IShareToken(IAsyncVault(vault_).share());
        shareToken.burn(address(poolEscrowProvider.escrow(poolId.raw())), shares);

        IAsyncVault(vault_).onRedeemClaimable(user, assets, shares);
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
        address vault_ = vault[poolId.raw()][scId.raw()][assetId.raw()];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelDepositRequest == true, NoPendingRequest());

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        IAsyncVault(vault_).onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillCancelRedeemRequest(PoolId poolId, ShareClassId scId, address user, AssetId assetId, uint128 shares)
        public
        auth
    {
        address vault_ = vault[poolId.raw()][scId.raw()][assetId.raw()];
        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelRedeemRequest == true, NoPendingRequest());

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        IAsyncVault(vault_).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function triggerRedeemRequest(PoolId poolId, ShareClassId scId, address user, AssetId assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, ShareTokenAmountIsZero());
        address vault_ = vault[poolId.raw()][scId.raw()][assetId.raw()];

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
                IShareToken(address(IAsyncVault(vault_).share())).authTransferFrom(
                    user, user, address(poolEscrowProvider.escrow(poolId.raw())), tokensToTransfer
                ),
                ShareTokenTransferFailed()
            );
        }

        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());
        emit TriggerRedeemRequest(poolId.raw(), scId.raw(), user, asset, tokenId, shares);
        IAsyncVault(vault_).onRedeemRequest(user, user, shares);
    }

    // --- Sync investment handlers ---
    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vaultAddr, controller), ExceedsMaxDeposit());

        AsyncInvestmentState storage state = investments[vaultAddr][controller];

        uint128 sharesUp = _calculateShares(vaultAddr, assets.toUint128(), state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _calculateShares(vaultAddr, assets.toUint128(), state.depositPrice, MathLib.Rounding.Down);
        _processDeposit(state, sharesUp, sharesDown, vaultAddr, receiver);
        shares = uint256(sharesDown);
    }

    /// @inheritdoc IDepositManager
    function mint(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        uint128 shares_ = shares.toUint128();
        _processDeposit(state, shares_, shares_, vaultAddr, receiver);

        assets = uint256(_calculateAssets(vaultAddr, shares_, state.depositPrice, MathLib.Rounding.Down));
    }

    function _processDeposit(
        AsyncInvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        address vaultAddr,
        address receiver
    ) internal {
        require(sharesUp <= state.maxMint, ExceedsDepositLimits());
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;

        IAsyncVault vault_ = IAsyncVault(vaultAddr);
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
    function redeem(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vaultAddr, controller), ExceedsMaxRedeem());

        AsyncInvestmentState storage state = investments[vaultAddr][controller];

        uint128 assetsUp = _calculateAssets(vaultAddr, shares.toUint128(), state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _calculateAssets(vaultAddr, shares.toUint128(), state.redeemPrice, MathLib.Rounding.Down);
        _processRedeem(state, assetsUp, assetsDown, vaultAddr, receiver, controller);
        assets = uint256(assetsDown);
    }

    /// @inheritdoc IRedeemManager
    function withdraw(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vaultAddr, receiver, controller);

        shares = uint256(_calculateShares(vaultAddr, assets_, state.redeemPrice, MathLib.Rounding.Down));
    }

    function _processRedeem(
        AsyncInvestmentState storage state,
        uint128 assetsUp,
        uint128 assetsDown,
        address vaultAddr,
        address receiver,
        address controller
    ) internal {
        if (controller != receiver) {
            require(
                _canTransfer(vaultAddr, controller, receiver, convertToShares(vaultAddr, assetsDown)),
                TransferNotAllowed()
            );
        }

        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assetsDown)), TransferNotAllowed()
        );

        require(assetsUp <= state.maxWithdraw, ExceedsRedeemLimits());
        state.maxWithdraw = state.maxWithdraw > assetsUp ? state.maxWithdraw - assetsUp : 0;

        if (assetsDown > 0) {
            _withdraw(vaultAddr, receiver, assetsDown);
        }
    }

    /// @dev Transfer funds from escrow to receiver and update holdings
    function _withdraw(address vaultAddr, address receiver, uint128 assets) internal {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);

        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        uint64 poolId = vault_.poolId();
        bytes16 scId = vault_.scId();

        Prices memory prices =
            sharePriceProvider.prices(poolId, scId, vaultDetails.assetId, vaultDetails.asset, vaultDetails.tokenId);
        IPoolEscrow(address(poolEscrowProvider.escrow(poolId))).reserveDecrease(
            scId, vaultDetails.asset, vaultDetails.tokenId, assets
        );

        balanceSheet.withdraw(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            vaultDetails.asset,
            vaultDetails.tokenId,
            receiver,
            assets,
            prices.poolPerAsset
        );
    }

    /// @inheritdoc IAsyncDepositManager
    function claimCancelDepositRequest(address vaultAddr, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        assets = state.claimableCancelDepositRequest;
        state.claimableCancelDepositRequest = 0;
        uint256 shares = convertToShares(vaultAddr, assets);

        if (controller != receiver) {
            require(_canTransfer(vaultAddr, controller, receiver, shares), TransferNotAllowed());
        }
        require(_canTransfer(vaultAddr, receiver, address(0), shares), TransferNotAllowed());

        if (assets > 0) {
            VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);

            address escrow = address(poolEscrowProvider.escrow(IAsyncVault(vaultAddr).poolId()));
            if (vaultDetails.tokenId == 0) {
                SafeTransferLib.safeTransferFrom(vaultDetails.asset, escrow, receiver, assets);
            } else {
                IERC6909(vaultDetails.asset).transferFrom(escrow, receiver, vaultDetails.tokenId, assets);
            }
        }
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimCancelRedeemRequest(address vaultAddr, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;
        IAsyncVault vault_ = IAsyncVault(vaultAddr);

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
    function maxDeposit(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, ESCROW_HOOK_ID, user, 0)) {
            return 0;
        }
        assets = uint256(_maxDeposit(vaultAddr, user));
    }

    function _maxDeposit(address vaultAddr, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vaultAddr][user];

        assets = _calculateAssets(vaultAddr, state.maxMint, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function maxMint(address vaultAddr, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vaultAddr, ESCROW_HOOK_ID, user, 0)) {
            return 0;
        }
        shares = uint256(investments[vaultAddr][user].maxMint);
    }

    /// @inheritdoc IRedeemManager
    function maxWithdraw(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, user, address(0), 0)) return 0;
        assets = uint256(investments[vaultAddr][user].maxWithdraw);
    }

    /// @inheritdoc IRedeemManager
    function maxRedeem(address vaultAddr, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vaultAddr, user, address(0), 0)) return 0;
        AsyncInvestmentState memory state = investments[vaultAddr][user];

        shares = uint256(_calculateShares(vaultAddr, state.maxWithdraw, state.redeemPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IAsyncDepositManager
    function pendingDepositRequest(address vaultAddr, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vaultAddr][user].pendingDepositRequest);
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vaultAddr][user].pendingRedeemRequest);
    }

    /// @inheritdoc IAsyncDepositManager
    function pendingCancelDepositRequest(address vaultAddr, address user) public view returns (bool isPending) {
        isPending = investments[vaultAddr][user].pendingCancelDepositRequest;
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingCancelRedeemRequest(address vaultAddr, address user) public view returns (bool isPending) {
        isPending = investments[vaultAddr][user].pendingCancelRedeemRequest;
    }

    /// @inheritdoc IAsyncDepositManager
    function claimableCancelDepositRequest(address vaultAddr, address user) public view returns (uint256 assets) {
        assets = investments[vaultAddr][user].claimableCancelDepositRequest;
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimableCancelRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        shares = investments[vaultAddr][user].claimableCancelRedeemRequest;
    }

    /// @inheritdoc IVaultManager
    function vaultByAssetId(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (address) {
        return vault[poolId][scId][assetId];
    }

    /// @inheritdoc IVaultManager
    function vaultKind(address) public pure returns (VaultKind, address) {
        return (VaultKind.Async, address(0));
    }

    // --- Helpers ---
    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(address vaultAddr, address from, address to, uint256 value) internal view returns (bool) {
        IShareToken share = IShareToken(IAsyncVault(vaultAddr).share());
        return share.checkTransferRestriction(from, to, value);
    }

    function _calculateShares(address vaultAddr, uint128 assets, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        address shareToken = IAsyncVault(vaultAddr).share();

        return VaultPricingLib.calculateShares(
            shareToken, vaultDetails.asset, vaultDetails.tokenId, assets, price, rounding
        );
    }

    function _calculateAssets(address vaultAddr, uint128 shares, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 assets)
    {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        address shareToken = IAsyncVault(vaultAddr).share();

        return VaultPricingLib.calculateAssets(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, price, rounding
        );
    }

    function _calculatePrice(address vaultAddr, uint128 shares, uint128 assets) internal view returns (uint256 price) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        address shareToken = IAsyncVault(vaultAddr).share();

        return VaultPricingLib.calculatePrice(shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets);
    }
}

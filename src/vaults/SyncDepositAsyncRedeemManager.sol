// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IRedeemGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {ISyncDepositAsyncRedeemManager} from "src/vaults/interfaces/investments/ISyncDepositAsyncRedeemManager.sol";
import {IAsyncRedeemManager, AsyncRedeemState} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {AsyncRedeemVault} from "src/vaults/AsyncRedeemVault.sol";
import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";

// TODO(@wischli) implement IUpdateContract for max price age
/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncDepositAsyncRedeemManager is Auth, ISyncDepositAsyncRedeemManager, IVaultManager, IRedeemGatewayHandler {
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    address public immutable escrow;

    IGateway public gateway;
    IVaultMessageSender public sender;
    IPoolManager public poolManager;

    mapping(address vaultAddr => uint64) public maxPriceAge;
    mapping(uint64 poolId => mapping(bytes16 trancheId => mapping(uint128 assetId => address vault))) public vault;
    mapping(address vault => mapping(address investor => AsyncRedeemState)) public redemptions;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("SyncDepositAsyncRedeemManager/file-unrecognized-param");
        emit IBaseInvestmentManager.File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId, address to, uint256 amount) external auth {
        if (tokenId == 0) {
            SafeTransferLib.safeTransfer(token, to, amount);
        } else {
            IERC6909(token).transfer(to, tokenId, amount);
        }
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncDepositAsyncRedeemManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] == address(0), "SyncDepositAsyncRedeemManager/vault-already-exists");

        vault[poolId][trancheId][assetId] = vaultAddr;

        IAuth(token).rely(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncDepositAsyncRedeemManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] != address(0), "SyncDepositAsyncRedeemManager/vault-does-not-exist");

        delete vault[poolId][trancheId][assetId];

        IAuth(token).deny(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);
    }

    // --- IDepositManager ---
    /// @inheritdoc IDepositManager
    function maxDeposit(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        shares = PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        ITranche tranche = ITranche(SyncDepositVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc IDepositManager
    function maxMint(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncDepositManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        assets = PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = previewMint(vaultAddr, owner, shares);

        ITranche tranche = ITranche(SyncDepositVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    // -- IAsyncRedeemManager --
    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(address vaultAddr, uint256 shares, address controller, address owner, address source)
        public
        auth
        returns (bool)
    {
        uint128 _shares = shares.toUint128();
        require(_shares != 0, "SyncDepositAsyncRedeemManager/zero-amount-not-allowed");
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), vault_.asset(), vaultAddr),
            "SyncDepositAsyncRedeemManager/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, owner, address(escrow), shares)
                && _canTransfer(vaultAddr, controller, address(escrow), shares),
            "SyncDepositAsyncRedeemManager/transfer-not-allowed"
        );

        return _processRedeemRequest(vaultAddr, _shares, controller, source, false);
    }

    /// @dev    triggered indicates if the the _processRedeemRequest call was triggered from centrifugeChain
    function _processRedeemRequest(
        address vaultAddr,
        uint128 shares,
        address controller,
        address source,
        bool triggered
    ) internal returns (bool) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        AsyncRedeemState storage state = redemptions[vaultAddr][controller];
        require(
            state.pendingCancelRedeemRequest != true || triggered,
            "SyncDepositAsyncRedeemManager/cancellation-is-pending"
        );

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        gateway.setPayableSource(source);
        sender.sendRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId, shares
        );

        return true;
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(address vaultAddr, address controller, address source) public auth {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        uint256 approximateTranchesPayout = pendingRedeemRequest(vaultAddr, controller);
        require(approximateTranchesPayout > 0, "SyncDepositAsyncRedeemManager/no-pending-redeem-request");
        require(
            _canTransfer(vaultAddr, address(0), controller, approximateTranchesPayout),
            "SyncDepositAsyncRedeemManager/transfer-not-allowed"
        );

        AsyncRedeemState storage state = redemptions[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true, "SyncDepositAsyncRedeemManager/cancellation-is-pending");
        state.pendingCancelRedeemRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        gateway.setPayableSource(source);
        sender.sendCancelRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId
        );
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimCancelRedeemRequest(address vaultAddr, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        AsyncRedeemState storage state = redemptions[vaultAddr][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;
        if (shares > 0) {
            require(
                IERC20(SyncDepositVault(vaultAddr).share()).transferFrom(address(escrow), receiver, shares),
                "SyncDepositAsyncRedeemManager/tranche-tokens-transfer-failed"
            );
        }
    }

    /// @inheritdoc IRedeemManager
    function redeem(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vaultAddr, controller), "SyncDepositAsyncRedeemManager/exceeds-max-redeem");

        AsyncRedeemState storage state = redemptions[vaultAddr][controller];
        uint128 assetsUp =
            PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown =
            PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, state.redeemPrice, MathLib.Rounding.Down);
        _processRedeem(state, assetsUp, assetsDown, vaultAddr, receiver, controller);
        assets = uint256(assetsDown);
    }

    /// @inheritdoc IRedeemManager
    function withdraw(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        AsyncRedeemState storage state = redemptions[vaultAddr][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vaultAddr, receiver, controller);
        shares =
            uint256(PriceConversionLib.calculateShares(assets_, vaultAddr, state.redeemPrice, MathLib.Rounding.Down));
    }

    function _processRedeem(
        AsyncRedeemState storage state,
        uint128 assetsUp,
        uint128 assetsDown,
        address vaultAddr,
        address receiver,
        address controller
    ) internal {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        if (controller != receiver) {
            require(
                _canTransfer(vaultAddr, controller, receiver, convertToShares(vaultAddr, assetsDown)),
                "SyncDepositAsyncRedeemManager/transfer-not-allowed"
            );
        }

        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assetsDown)),
            "SyncDepositAsyncRedeemManager/transfer-not-allowed"
        );

        require(assetsUp <= state.maxWithdraw, "SyncDepositAsyncRedeemManager/exceeds-redeem-limits");
        state.maxWithdraw = state.maxWithdraw > assetsUp ? state.maxWithdraw - assetsUp : 0;

        if (assetsDown > 0) {
            VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

            if (vaultDetails.tokenId == 0) {
                SafeTransferLib.safeTransferFrom(vaultDetails.asset, address(escrow), receiver, assetsDown);
            } else {
                IERC6909(vaultDetails.asset).transferFrom(address(escrow), receiver, vaultDetails.tokenId, assetsDown);
            }
        }
    }

    // -- Gateway handlers --
    /// @inheritdoc IRedeemGatewayHandler
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault_ = vault[poolId][trancheId][assetId];

        AsyncRedeemState storage state = redemptions[vault_][user];
        require(state.pendingRedeemRequest != 0, "SyncDepositAsyncRedeemManager/no-pending-redeem-request");

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice = PriceConversionLib.calculatePrice(
            vault_, state.maxWithdraw + assets, ((maxRedeem(vault_, user)) + shares).toUint128()
        );
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed tranche tokens from escrow
        SyncDepositVault syncVault = SyncDepositVault(vault_);
        ITranche tranche = ITranche(syncVault.share());
        tranche.burn(address(escrow), shares);

        syncVault.onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IRedeemGatewayHandler
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        address vault_ = vault[poolId][trancheId][assetId];
        AsyncRedeemState storage state = redemptions[vault_][user];
        require(
            state.pendingCancelRedeemRequest == true, "SyncDepositAsyncRedeemManager/no-pending-cancel-redeem-request"
        );

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        SyncDepositVault(vault_).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IRedeemGatewayHandler
    function triggerRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, "SyncDepositAsyncRedeemManager/tranche-token-amount-is-zero");
        address vault_ = vault[poolId][trancheId][assetId];

        // If there's any unclaimed deposits, claim those first
        AsyncRedeemState storage state = redemptions[vault_][user];
        uint128 tokensToTransfer = shares;

        // FIXME(wischli): Probably use this.maxMint which is unfinished
        // if (state.maxMint >= shares) {
        //     // The full redeem request is covered by the claimable amount
        //     tokensToTransfer = 0;
        //     state.maxMint = state.maxMint - shares;
        // } else if (state.maxMint != 0) {
        //     // The redeem request is only partially covered by the claimable amount
        //     tokensToTransfer = shares - state.maxMint;
        //     state.maxMint = 0;
        // }

        require(
            _processRedeemRequest(vault_, shares, user, msg.sender, true),
            "SyncDepositAsyncRedeemManager/failed-redeem-request"
        );

        // Transfer the tranche token amount that was not covered by tokens still in escrow for claims,
        // from user to escrow (lock tranche tokens in escrow)
        SyncDepositVault syncVault = SyncDepositVault(vault_);
        if (tokensToTransfer != 0) {
            require(
                ITranche(address(syncVault.share())).authTransferFrom(user, user, address(escrow), tokensToTransfer),
                "SyncDepositAsyncRedeemManager/transfer-failed"
            );
        }

        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        emit TriggerRedeemRequest(poolId, trancheId, user, asset, tokenId, shares);
        syncVault.onRedeemRequest(user, user, shares);
    }

    // --- View functions ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(address vaultAddr, uint256 _assets) public view returns (uint256 shares) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (uint128 latestPrice,) = poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        shares = uint256(
            PriceConversionLib.calculateShares(_assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down)
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(address vaultAddr, uint256 _shares) public view returns (uint256 assets) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (uint128 latestPrice,) = poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        assets = uint256(
            PriceConversionLib.calculateAssets(_shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down)
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function vaultByAssetId(uint64 poolId, bytes16 trancheId, uint128 assetId) public view returns (address) {
        return vault[poolId][trancheId][assetId];
    }

    /// @inheritdoc IBaseInvestmentManager
    function priceLastUpdated(address vaultAddr) public view returns (uint64 lastUpdated) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (, lastUpdated) = poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        shares = uint256(redemptions[vaultAddr][user].pendingRedeemRequest);
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingCancelRedeemRequest(address vaultAddr, address user) public view returns (bool isPending) {
        isPending = redemptions[vaultAddr][user].pendingCancelRedeemRequest;
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimableCancelRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        shares = redemptions[vaultAddr][user].claimableCancelRedeemRequest;
    }

    /// @inheritdoc IRedeemManager
    function maxRedeem(address vaultAddr, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vaultAddr, user, address(0), 0)) return 0;
        AsyncRedeemState memory state = redemptions[vaultAddr][user];
        shares = uint256(
            PriceConversionLib.calculateShares(state.maxWithdraw, vaultAddr, state.redeemPrice, MathLib.Rounding.Down)
        );
    }

    /// @inheritdoc IRedeemManager
    function maxWithdraw(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, user, address(0), 0)) return 0;
        assets = uint256(redemptions[vaultAddr][user].maxWithdraw);
    }

    // --- Admin actions ---
    /// @inheritdoc IMessageHandler
    function handle(uint32 chainId, bytes calldata message) public auth {
        // TODO: updateMaxPriceAge handler
    }

    // --- Helpers ---
    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(address vaultAddr, address from, address to, uint256 value) internal view returns (bool) {
        ITranche share = ITranche(IBaseVault(vaultAddr).share());
        return share.checkTransferRestriction(from, to, value);
    }
}

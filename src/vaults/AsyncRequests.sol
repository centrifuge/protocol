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
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IInvestmentManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IAsyncRequests, AsyncInvestmentState} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IAsyncDepositManager} from "src/vaults/interfaces/investments/IAsyncDepositManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IVaultManager, VaultKind} from "src/vaults/interfaces/IVaultManager.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncVault} from "src/vaults/interfaces/IERC7540.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";

/// @title  Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncRequests is BaseInvestmentManager, IAsyncRequests {
    using BytesLib for bytes;
    using MathLib for uint256;
    using MessageLib for *;
    using CastLib for *;

    IVaultMessageSender public sender;

    mapping(address vault => mapping(address investor => AsyncInvestmentState)) public investments;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(uint128 assetId => address vault))) public vault;

    constructor(address root_, address escrow_) BaseInvestmentManager(root_, escrow_) {}

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("AsyncRequests/file-unrecognized-param");
        emit File(what, data);
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "AsyncRequests/asset-mismatch");
        require(vault[poolId][scId][assetId] == address(0), "AsyncRequests/vault-already-exists");

        vault[poolId][scId][assetId] = vaultAddr;
        IAuth(token).rely(vaultAddr);
        IShareToken(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 scId, address vaultAddr, address asset_, uint128 assetId) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "AsyncRequests/asset-mismatch");
        require(vault[poolId][scId][assetId] != address(0), "AsyncRequests/vault-does-not-exist");

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
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        uint128 _assets = assets.toUint128();
        require(_assets != 0, "AsyncRequests/zero-amount-not-allowed");

        address asset = vault_.asset();
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), asset, vaultAddr),
            "AsyncRequests/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, address(0), controller, convertToShares(vaultAddr, assets)),
            "AsyncRequests/transfer-not-allowed"
        );

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelDepositRequest != true, "AsyncRequests/cancellation-is-pending");

        state.pendingDepositRequest = state.pendingDepositRequest + _assets;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendDepositRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId, _assets
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
        require(_shares != 0, "AsyncRequests/zero-amount-not-allowed");
        IAsyncVault vault_ = IAsyncVault(vaultAddr);

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), vault_.asset(), vaultAddr),
            "AsyncRequests/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, owner, address(escrow), shares)
                && _canTransfer(vaultAddr, controller, address(escrow), shares),
            "AsyncRequests/transfer-not-allowed"
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
        require(state.pendingCancelRedeemRequest != true || triggered, "AsyncRequests/cancellation-is-pending");

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId, shares
        );

        return true;
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(address vaultAddr, address controller, address) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingDepositRequest > 0, "AsyncRequests/no-pending-deposit-request");
        require(state.pendingCancelDepositRequest != true, "AsyncRequests/cancellation-is-pending");
        state.pendingCancelDepositRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendCancelDepositRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId
        );
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(address vaultAddr, address controller, address) public auth {
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        uint256 approximateSharesPayout = pendingRedeemRequest(vaultAddr, controller);
        require(approximateSharesPayout > 0, "AsyncRequests/no-pending-redeem-request");
        require(
            _canTransfer(vaultAddr, address(0), controller, approximateSharesPayout),
            "AsyncRequests/transfer-not-allowed"
        );

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true, "AsyncRequests/cancellation-is-pending");
        state.pendingCancelRedeemRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        sender.sendCancelRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId
        );
    }

    // -- Gateway handlers --
    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault_ = vault[poolId][scId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingDepositRequest != 0, "AsyncRequests/no-pending-deposit-request");
        state.depositPrice = _calculatePrice(vault_, state.maxMint + shares, _maxDeposit(vault_, user) + assets);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint to escrow. Recipient can claim by calling deposit / mint
        IShareToken shareToken = IShareToken(IAsyncVault(vault_).share());
        shareToken.mint(address(escrow), shares);

        IAsyncVault(vault_).onDepositClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault_ = vault[poolId][scId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingRedeemRequest != 0, "AsyncRequests/no-pending-redeem-request");

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice =
            _calculatePrice(vault_, ((maxRedeem(vault_, user)) + shares).toUint128(), state.maxWithdraw + assets);
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed share class tokens from escrow
        IShareToken shareToken = IShareToken(IAsyncVault(vault_).share());
        shareToken.burn(address(escrow), shares);

        IAsyncVault(vault_).onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public auth {
        address vault_ = vault[poolId][scId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelDepositRequest == true, "AsyncRequests/no-pending-cancel-deposit-request");

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        IAsyncVault(vault_).onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 scId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        address vault_ = vault[poolId][scId][assetId];
        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelRedeemRequest == true, "AsyncRequests/no-pending-cancel-redeem-request");

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        IAsyncVault(vault_).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IInvestmentManagerGatewayHandler
    function triggerRedeemRequest(uint64 poolId, bytes16 scId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, "AsyncRequests/share-token-amount-is-zero");
        address vault_ = vault[poolId][scId][assetId];

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

        require(_processRedeemRequest(vault_, shares, user, msg.sender, true), "AsyncRequests/failed-redeem-request");

        // Transfer the token token amount that was not covered by tokens still in escrow for claims,
        // from user to escrow (lock share class tokens in escrow)
        if (tokensToTransfer != 0) {
            require(
                IShareToken(address(IAsyncVault(vault_).share())).authTransferFrom(
                    user, user, address(escrow), tokensToTransfer
                ),
                "AsyncRequests/transfer-failed"
            );
        }

        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        emit TriggerRedeemRequest(poolId, scId, user, asset, tokenId, shares);
        IAsyncVault(vault_).onRedeemRequest(user, user, shares);
    }

    // --- Sync investment handlers ---
    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vaultAddr, controller), "AsyncRequests/exceeds-max-deposit");

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
        require(sharesUp <= state.maxMint, "AsyncRequests/exceeds-deposit-limits");
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;
        if (sharesDown > 0) {
            require(
                IERC20(IAsyncVault(vaultAddr).share()).transferFrom(address(escrow), receiver, sharesDown),
                "AsyncRequests/share-tokens-transfer-failed"
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
        require(shares <= maxRedeem(vaultAddr, controller), "AsyncRequests/exceeds-max-redeem");

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
        IAsyncVault vault_ = IAsyncVault(vaultAddr);
        if (controller != receiver) {
            require(
                _canTransfer(vaultAddr, controller, receiver, convertToShares(vaultAddr, assetsDown)),
                "AsyncRequests/transfer-not-allowed"
            );
        }

        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assetsDown)),
            "AsyncRequests/transfer-not-allowed"
        );

        require(assetsUp <= state.maxWithdraw, "AsyncRequests/exceeds-redeem-limits");
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

    /// @inheritdoc IAsyncDepositManager
    function claimCancelDepositRequest(address vaultAddr, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        assets = state.claimableCancelDepositRequest;
        state.claimableCancelDepositRequest = 0;

        if (controller != receiver) {
            require(
                _canTransfer(vaultAddr, controller, receiver, convertToShares(vaultAddr, assets)),
                "AsyncRequests/transfer-not-allowed"
            );
        }
        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assets)),
            "AsyncRequests/transfer-not-allowed"
        );

        if (assets > 0) {
            VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);

            if (vaultDetails.tokenId == 0) {
                SafeTransferLib.safeTransferFrom(vaultDetails.asset, address(escrow), receiver, assets);
            } else {
                IERC6909(vaultDetails.asset).transferFrom(address(escrow), receiver, vaultDetails.tokenId, assets);
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
        if (shares > 0) {
            require(
                IERC20(IAsyncVault(vaultAddr).share()).transferFrom(address(escrow), receiver, shares),
                "AsyncRequests/share-tokens-transfer-failed"
            );
        }
    }

    // --- View functions ---
    /// @inheritdoc IDepositManager
    function maxDeposit(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, address(escrow), user, 0)) return 0;
        assets = uint256(_maxDeposit(vaultAddr, user));
    }

    function _maxDeposit(address vaultAddr, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vaultAddr][user];

        assets = _calculateAssets(vaultAddr, state.maxMint, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function maxMint(address vaultAddr, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vaultAddr, address(escrow), user, 0)) return 0;
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

        return PriceConversionLib.calculateShares(
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

        return PriceConversionLib.calculateAssets(
            shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, price, rounding
        );
    }

    function _calculatePrice(address vaultAddr, uint128 shares, uint128 assets) internal view returns (uint256 price) {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        address shareToken = IAsyncVault(vaultAddr).share();

        return PriceConversionLib.calculatePrice(shareToken, shares, vaultDetails.asset, vaultDetails.tokenId, assets);
    }
}

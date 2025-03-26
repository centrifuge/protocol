// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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
import {IDepositGatewayHandler, IRedeemGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {
    IAsyncInvestmentManager,
    AsyncInvestmentState
} from "src/vaults/interfaces/investments/IAsyncInvestmentManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IAsyncDepositManager} from "src/vaults/interfaces/investments/IAsyncDepositManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IERC7540Vault} from "src/vaults/interfaces/IERC7540.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {BaseInvestmentManager} from "src/vaults/BaseInvestmentManager.sol";

/// @title  Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract AsyncInvestmentManager is
    BaseInvestmentManager,
    IAsyncInvestmentManager,
    IDepositGatewayHandler,
    IRedeemGatewayHandler
{
    using BytesLib for bytes;
    using MathLib for uint256;
    using MessageLib for *;
    using CastLib for *;

    IGateway public gateway;
    IVaultMessageSender public sender;

    mapping(address vault => mapping(address investor => AsyncInvestmentState)) public investments;

    constructor(address root_, address escrow_) BaseInvestmentManager(root_, escrow_) {}

    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external override(IBaseInvestmentManager, BaseInvestmentManager) auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("AsyncInvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        auth
    {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "AsyncInvestmentManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] == address(0), "AsyncInvestmentManager/vault-already-exists");

        vault[poolId][trancheId][assetId] = vaultAddr;

        IAuth(token).rely(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        auth
    {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "AsyncInvestmentManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] != address(0), "AsyncInvestmentManager/vault-does-not-exist");

        delete vault[poolId][trancheId][assetId];

        IAuth(token).deny(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);
    }

    /// @inheritdoc IAsyncDepositManager
    function requestDeposit(address vaultAddr, uint256 assets, address controller, address, /* owner */ address source)
        public
        auth
        returns (bool)
    {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        uint128 _assets = assets.toUint128();
        require(_assets != 0, "AsyncInvestmentManager/zero-amount-not-allowed");

        address asset = vault_.asset();
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), asset, vaultAddr),
            "AsyncInvestmentManager/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, address(0), controller, convertToShares(vaultAddr, assets)),
            "AsyncInvestmentManager/transfer-not-allowed"
        );

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelDepositRequest != true, "AsyncInvestmentManager/cancellation-is-pending");

        state.pendingDepositRequest = state.pendingDepositRequest + _assets;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        gateway.setPayableSource(source);
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
        require(_shares != 0, "AsyncInvestmentManager/zero-amount-not-allowed");
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), vault_.asset(), vaultAddr),
            "AsyncInvestmentManager/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, owner, address(escrow), shares)
                && _canTransfer(vaultAddr, controller, address(escrow), shares),
            "AsyncInvestmentManager/transfer-not-allowed"
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
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true || triggered, "AsyncInvestmentManager/cancellation-is-pending");

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        gateway.setPayableSource(source);
        sender.sendRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId, shares
        );

        return true;
    }

    /// @inheritdoc IAsyncDepositManager
    function cancelDepositRequest(address vaultAddr, address controller, address source) public auth {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingDepositRequest > 0, "AsyncInvestmentManager/no-pending-deposit-request");
        require(state.pendingCancelDepositRequest != true, "AsyncInvestmentManager/cancellation-is-pending");
        state.pendingCancelDepositRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        gateway.setPayableSource(source);
        sender.sendCancelDepositRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId
        );
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(address vaultAddr, address controller, address source) public auth {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        uint256 approximateTranchesPayout = pendingRedeemRequest(vaultAddr, controller);
        require(approximateTranchesPayout > 0, "AsyncInvestmentManager/no-pending-redeem-request");
        require(
            _canTransfer(vaultAddr, address(0), controller, approximateTranchesPayout),
            "AsyncInvestmentManager/transfer-not-allowed"
        );

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true, "AsyncInvestmentManager/cancellation-is-pending");
        state.pendingCancelRedeemRequest = true;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));

        gateway.setPayableSource(source);
        sender.sendCancelRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), vaultDetails.assetId
        );
    }

    // -- Gateway handlers --
    /// @inheritdoc IDepositGatewayHandler
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault_ = vault[poolId][trancheId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingDepositRequest != 0, "AsyncInvestmentManager/no-pending-deposit-request");
        state.depositPrice =
            PriceConversionLib.calculatePrice(vault_, _maxDeposit(vault_, user) + assets, state.maxMint + shares);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint to escrow. Recipient can claim by calling deposit / mint
        ITranche tranche = ITranche(IERC7540Vault(vault_).share());
        tranche.mint(address(escrow), shares);

        IERC7540Vault(vault_).onDepositClaimable(user, assets, shares);
    }

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

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingRedeemRequest != 0, "AsyncInvestmentManager/no-pending-redeem-request");

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice = PriceConversionLib.calculatePrice(
            vault_, state.maxWithdraw + assets, ((maxRedeem(vault_, user)) + shares).toUint128()
        );
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed tranche tokens from escrow
        ITranche tranche = ITranche(IERC7540Vault(vault_).share());
        tranche.burn(address(escrow), shares);

        // TODO: Use IAsyncRedeemVault interface instead
        IERC7540Vault(vault_).onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IDepositGatewayHandler
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public auth {
        address vault_ = vault[poolId][trancheId][assetId];

        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelDepositRequest == true, "AsyncInvestmentManager/no-pending-cancel-deposit-request");

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        IERC7540Vault(vault_).onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IRedeemGatewayHandler
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        address vault_ = vault[poolId][trancheId][assetId];
        AsyncInvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelRedeemRequest == true, "AsyncInvestmentManager/no-pending-cancel-redeem-request");

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        IERC7540Vault(vault_).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IRedeemGatewayHandler
    function triggerRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, "AsyncInvestmentManager/tranche-token-amount-is-zero");
        address vault_ = vault[poolId][trancheId][assetId];

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

        require(
            _processRedeemRequest(vault_, shares, user, msg.sender, true),
            "AsyncInvestmentManager/failed-redeem-request"
        );

        // Transfer the tranche token amount that was not covered by tokens still in escrow for claims,
        // from user to escrow (lock tranche tokens in escrow)
        if (tokensToTransfer != 0) {
            require(
                ITranche(address(IERC7540Vault(vault_).share())).authTransferFrom(
                    user, user, address(escrow), tokensToTransfer
                ),
                "AsyncInvestmentManager/transfer-failed"
            );
        }

        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        emit TriggerRedeemRequest(poolId, trancheId, user, asset, tokenId, shares);
        IERC7540Vault(vault_).onRedeemRequest(user, user, shares);
    }

    // --- View functions ---
    /// @inheritdoc IDepositManager
    function maxDeposit(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, address(escrow), user, 0)) return 0;
        assets = uint256(_maxDeposit(vaultAddr, user));
    }

    function _maxDeposit(address vaultAddr, address user) internal view returns (uint128 assets) {
        AsyncInvestmentState memory state = investments[vaultAddr][user];
        assets = PriceConversionLib.calculateAssets(state.maxMint, vaultAddr, state.depositPrice, MathLib.Rounding.Down);
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
        shares = uint256(
            PriceConversionLib.calculateShares(state.maxWithdraw, vaultAddr, state.redeemPrice, MathLib.Rounding.Down)
        );
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

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vaultAddr, controller), "AsyncInvestmentManager/exceeds-max-deposit");

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        uint128 sharesUp =
            PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown =
            PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, state.depositPrice, MathLib.Rounding.Down);
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
        assets =
            uint256(PriceConversionLib.calculateAssets(shares_, vaultAddr, state.depositPrice, MathLib.Rounding.Down));
    }

    function _processDeposit(
        AsyncInvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        address vaultAddr,
        address receiver
    ) internal {
        require(sharesUp <= state.maxMint, "AsyncInvestmentManager/exceeds-deposit-limits");
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;
        if (sharesDown > 0) {
            require(
                IERC20(IERC7540Vault(vaultAddr).share()).transferFrom(address(escrow), receiver, sharesDown),
                "AsyncInvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    /// @inheritdoc IRedeemManager
    function redeem(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vaultAddr, controller), "AsyncInvestmentManager/exceeds-max-redeem");

        AsyncInvestmentState storage state = investments[vaultAddr][controller];
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
        AsyncInvestmentState storage state = investments[vaultAddr][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vaultAddr, receiver, controller);
        shares =
            uint256(PriceConversionLib.calculateShares(assets_, vaultAddr, state.redeemPrice, MathLib.Rounding.Down));
    }

    function _processRedeem(
        AsyncInvestmentState storage state,
        uint128 assetsUp,
        uint128 assetsDown,
        address vaultAddr,
        address receiver,
        address controller
    ) internal {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        if (controller != receiver) {
            require(
                _canTransfer(vaultAddr, controller, receiver, convertToShares(vaultAddr, assetsDown)),
                "AsyncInvestmentManager/transfer-not-allowed"
            );
        }

        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assetsDown)),
            "AsyncInvestmentManager/transfer-not-allowed"
        );

        require(assetsUp <= state.maxWithdraw, "AsyncInvestmentManager/exceeds-redeem-limits");
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
                "AsyncInvestmentManager/transfer-not-allowed"
            );
        }
        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assets)),
            "AsyncInvestmentManager/transfer-not-allowed"
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
                IERC20(IERC7540Vault(vaultAddr).share()).transferFrom(address(escrow), receiver, shares),
                "AsyncInvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    // --- Helpers ---
    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(address vaultAddr, address from, address to, uint256 value) internal view returns (bool) {
        ITranche share = ITranche(IERC7540Vault(vaultAddr).share());
        return share.checkTransferRestriction(from, to, value);
    }
}

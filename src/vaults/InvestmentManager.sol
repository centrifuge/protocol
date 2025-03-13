// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IInvestmentManager, InvestmentState} from "src/vaults/interfaces/IInvestmentManager.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IERC7540Vault} from "src/vaults/interfaces/IERC7540.sol";
import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";

/// @title  Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract InvestmentManager is Auth, IInvestmentManager {
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    /// @dev Prices are fixed-point integers with 18 decimals
    uint8 internal constant PRICE_DECIMALS = 18;

    address public immutable root;
    address public immutable escrow;

    IGateway public gateway;
    IMessageProcessor public sender;
    IPoolManager public poolManager;

    mapping(uint64 poolId => mapping(bytes16 trancheId => mapping(uint128 assetId => address vault))) public vault;

    /// @inheritdoc IInvestmentManager
    mapping(address vault => mapping(address investor => InvestmentState)) public investments;

    constructor(address root_, address escrow_) Auth(msg.sender) {
        root = root_;
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc IInvestmentManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "sender") sender = IMessageProcessor(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("InvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "InvestmentManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] == address(0), "InvestmentManager/vault-already-exists");

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
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "InvestmentManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] != address(0), "InvestmentManager/vault-does-not-exist");

        delete vault[poolId][trancheId][assetId];

        IAuth(token).deny(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);
    }

    // --- Outgoing message handling ---
    /// @inheritdoc IInvestmentManager
    function requestDeposit(address vaultAddr, uint256 assets, address controller, address, /* owner */ address source)
        public
        auth
        returns (bool)
    {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        uint128 _assets = assets.toUint128();
        require(_assets != 0, "InvestmentManager/zero-amount-not-allowed");

        address asset = vault_.asset();
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), asset, vaultAddr),
            "InvestmentManager/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, address(0), controller, convertToShares(vaultAddr, assets)),
            "InvestmentManager/transfer-not-allowed"
        );

        InvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelDepositRequest != true, "InvestmentManager/cancellation-is-pending");

        state.pendingDepositRequest = state.pendingDepositRequest + _assets;

        gateway.setPayableSource(source);
        sender.sendDepositRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), poolManager.assetToId(asset), _assets
        );

        return true;
    }

    /// @inheritdoc IInvestmentManager
    function requestRedeem(address vaultAddr, uint256 shares, address controller, address owner, address source)
        public
        auth
        returns (bool)
    {
        uint128 _shares = shares.toUint128();
        require(_shares != 0, "InvestmentManager/zero-amount-not-allowed");
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(
            poolManager.isLinked(vault_.poolId(), vault_.trancheId(), vault_.asset(), vaultAddr),
            "InvestmentManager/asset-not-allowed"
        );

        require(
            _canTransfer(vaultAddr, owner, address(escrow), shares)
                && _canTransfer(vaultAddr, controller, address(escrow), shares),
            "InvestmentManager/transfer-not-allowed"
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
        InvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true || triggered, "InvestmentManager/cancellation-is-pending");

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;

        gateway.setPayableSource(source);
        sender.sendRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), poolManager.assetToId(vault_.asset()), shares
        );

        return true;
    }

    /// @inheritdoc IInvestmentManager
    function cancelDepositRequest(address vaultAddr, address controller, address source) public auth {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);

        InvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingDepositRequest > 0, "InvestmentManager/no-pending-deposit-request");
        require(state.pendingCancelDepositRequest != true, "InvestmentManager/cancellation-is-pending");
        state.pendingCancelDepositRequest = true;

        gateway.setPayableSource(source);
        sender.sendCancelDepositRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), poolManager.assetToId(vault_.asset())
        );
    }

    /// @inheritdoc IInvestmentManager
    function cancelRedeemRequest(address vaultAddr, address controller, address source) public auth {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        uint256 approximateTranchesPayout = pendingRedeemRequest(vaultAddr, controller);
        require(approximateTranchesPayout > 0, "InvestmentManager/no-pending-redeem-request");
        require(
            _canTransfer(vaultAddr, address(0), controller, approximateTranchesPayout),
            "InvestmentManager/transfer-not-allowed"
        );

        InvestmentState storage state = investments[vaultAddr][controller];
        require(state.pendingCancelRedeemRequest != true, "InvestmentManager/cancellation-is-pending");
        state.pendingCancelRedeemRequest = true;

        gateway.setPayableSource(source);
        sender.sendCancelRedeemRequest(
            vault_.poolId(), vault_.trancheId(), controller.toBytes32(), poolManager.assetToId(vault_.asset())
        );
    }

    /// @inheritdoc IInvestmentManager
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault_ = vault[poolId][trancheId][assetId];

        InvestmentState storage state = investments[vault_][user];
        require(state.pendingDepositRequest != 0, "InvestmentManager/no-pending-deposit-request");
        state.depositPrice = _calculatePrice(vault_, _maxDeposit(vault_, user) + assets, state.maxMint + shares);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint to escrow. Recipient can claim by calling deposit / mint
        ITranche tranche = ITranche(IERC7540Vault(vault_).share());
        tranche.mint(address(escrow), shares);

        IERC7540Vault(vault_).onDepositClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault_ = vault[poolId][trancheId][assetId];

        InvestmentState storage state = investments[vault_][user];
        require(state.pendingRedeemRequest != 0, "InvestmentManager/no-pending-redeem-request");

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice =
            _calculatePrice(vault_, state.maxWithdraw + assets, ((maxRedeem(vault_, user)) + shares).toUint128());
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed tranche tokens from escrow
        ITranche tranche = ITranche(IERC7540Vault(vault_).share());
        tranche.burn(address(escrow), shares);

        IERC7540Vault(vault_).onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public auth {
        address vault_ = vault[poolId][trancheId][assetId];

        InvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelDepositRequest == true, "InvestmentManager/no-pending-cancel-deposit-request");

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        IERC7540Vault(vault_).onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        address vault_ = vault[poolId][trancheId][assetId];
        InvestmentState storage state = investments[vault_][user];
        require(state.pendingCancelRedeemRequest == true, "InvestmentManager/no-pending-cancel-redeem-request");

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        IERC7540Vault(vault_).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IInvestmentManager
    function triggerRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, "InvestmentManager/tranche-token-amount-is-zero");
        address vault_ = vault[poolId][trancheId][assetId];

        // If there's any unclaimed deposits, claim those first
        InvestmentState storage state = investments[vault_][user];
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
            _processRedeemRequest(vault_, shares, user, msg.sender, true), "InvestmentManager/failed-redeem-request"
        );

        // Transfer the tranche token amount that was not covered by tokens still in escrow for claims,
        // from user to escrow (lock tranche tokens in escrow)
        if (tokensToTransfer != 0) {
            require(
                ITranche(address(IERC7540Vault(vault_).share())).authTransferFrom(
                    user, user, address(escrow), tokensToTransfer
                ),
                "InvestmentManager/transfer-failed"
            );
        }

        emit TriggerRedeemRequest(poolId, trancheId, user, poolManager.idToAsset(assetId), shares);
        IERC7540Vault(vault_).onRedeemRequest(user, user, shares);
    }

    // --- View functions ---
    /// @inheritdoc IInvestmentManager
    function convertToShares(address vaultAddr, uint256 _assets) public view returns (uint256 shares) {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        (uint128 latestPrice,) = poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        shares = uint256(_calculateShares(_assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function convertToAssets(address vaultAddr, uint256 _shares) public view returns (uint256 assets) {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        (uint128 latestPrice,) = poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        assets = uint256(_calculateAssets(_shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function maxDeposit(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, address(escrow), user, 0)) return 0;
        assets = uint256(_maxDeposit(vaultAddr, user));
    }

    function _maxDeposit(address vaultAddr, address user) internal view returns (uint128 assets) {
        InvestmentState memory state = investments[vaultAddr][user];
        assets = _calculateAssets(state.maxMint, vaultAddr, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IInvestmentManager
    function maxMint(address vaultAddr, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vaultAddr, address(escrow), user, 0)) return 0;
        shares = uint256(investments[vaultAddr][user].maxMint);
    }

    /// @inheritdoc IInvestmentManager
    function maxWithdraw(address vaultAddr, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vaultAddr, user, address(0), 0)) return 0;
        assets = uint256(investments[vaultAddr][user].maxWithdraw);
    }

    /// @inheritdoc IInvestmentManager
    function maxRedeem(address vaultAddr, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vaultAddr, user, address(0), 0)) return 0;
        InvestmentState memory state = investments[vaultAddr][user];
        shares = uint256(_calculateShares(state.maxWithdraw, vaultAddr, state.redeemPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function pendingDepositRequest(address vaultAddr, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vaultAddr][user].pendingDepositRequest);
    }

    /// @inheritdoc IInvestmentManager
    function pendingRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vaultAddr][user].pendingRedeemRequest);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelDepositRequest(address vaultAddr, address user) public view returns (bool isPending) {
        isPending = investments[vaultAddr][user].pendingCancelDepositRequest;
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelRedeemRequest(address vaultAddr, address user) public view returns (bool isPending) {
        isPending = investments[vaultAddr][user].pendingCancelRedeemRequest;
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelDepositRequest(address vaultAddr, address user) public view returns (uint256 assets) {
        assets = investments[vaultAddr][user].claimableCancelDepositRequest;
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        shares = investments[vaultAddr][user].claimableCancelRedeemRequest;
    }

    /// @inheritdoc IInvestmentManager
    function priceLastUpdated(address vaultAddr) public view returns (uint64 lastUpdated) {
        IERC7540Vault vault_ = IERC7540Vault(vaultAddr);
        (, lastUpdated) = poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
    }

    // --- Vault claim functions ---
    /// @inheritdoc IInvestmentManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vaultAddr, controller), "InvestmentManager/exceeds-max-deposit");

        InvestmentState storage state = investments[vaultAddr][controller];
        uint128 sharesUp = _calculateShares(assets.toUint128(), vaultAddr, state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _calculateShares(assets.toUint128(), vaultAddr, state.depositPrice, MathLib.Rounding.Down);
        _processDeposit(state, sharesUp, sharesDown, vaultAddr, receiver);
        shares = uint256(sharesDown);
    }

    /// @inheritdoc IInvestmentManager
    function mint(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        InvestmentState storage state = investments[vaultAddr][controller];
        uint128 shares_ = shares.toUint128();
        _processDeposit(state, shares_, shares_, vaultAddr, receiver);
        assets = uint256(_calculateAssets(shares_, vaultAddr, state.depositPrice, MathLib.Rounding.Down));
    }

    function _processDeposit(
        InvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        address vaultAddr,
        address receiver
    ) internal {
        require(sharesUp <= state.maxMint, "InvestmentManager/exceeds-deposit-limits");
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;
        if (sharesDown > 0) {
            require(
                IERC20(IERC7540Vault(vaultAddr).share()).transferFrom(address(escrow), receiver, sharesDown),
                "InvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    /// @inheritdoc IInvestmentManager
    function redeem(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vaultAddr, controller), "InvestmentManager/exceeds-max-redeem");

        InvestmentState storage state = investments[vaultAddr][controller];
        uint128 assetsUp = _calculateAssets(shares.toUint128(), vaultAddr, state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _calculateAssets(shares.toUint128(), vaultAddr, state.redeemPrice, MathLib.Rounding.Down);
        _processRedeem(state, assetsUp, assetsDown, vaultAddr, receiver, controller);
        assets = uint256(assetsDown);
    }

    /// @inheritdoc IInvestmentManager
    function withdraw(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        InvestmentState storage state = investments[vaultAddr][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vaultAddr, receiver, controller);
        shares = uint256(_calculateShares(assets_, vaultAddr, state.redeemPrice, MathLib.Rounding.Down));
    }

    function _processRedeem(
        InvestmentState storage state,
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
                "InvestmentManager/transfer-not-allowed"
            );
        }

        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assetsDown)),
            "InvestmentManager/transfer-not-allowed"
        );

        require(assetsUp <= state.maxWithdraw, "InvestmentManager/exceeds-redeem-limits");
        state.maxWithdraw = state.maxWithdraw > assetsUp ? state.maxWithdraw - assetsUp : 0;
        if (assetsDown > 0) SafeTransferLib.safeTransferFrom(vault_.asset(), address(escrow), receiver, assetsDown);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelDepositRequest(address vaultAddr, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        InvestmentState storage state = investments[vaultAddr][controller];
        assets = state.claimableCancelDepositRequest;
        state.claimableCancelDepositRequest = 0;

        if (controller != receiver) {
            require(
                _canTransfer(vaultAddr, controller, receiver, convertToShares(vaultAddr, assets)),
                "InvestmentManager/transfer-not-allowed"
            );
        }
        require(
            _canTransfer(vaultAddr, receiver, address(0), convertToShares(vaultAddr, assets)),
            "InvestmentManager/transfer-not-allowed"
        );

        if (assets > 0) {
            SafeTransferLib.safeTransferFrom(IERC7540Vault(vaultAddr).asset(), address(escrow), receiver, assets);
        }
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelRedeemRequest(address vaultAddr, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        InvestmentState storage state = investments[vaultAddr][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;
        if (shares > 0) {
            require(
                IERC20(IERC7540Vault(vaultAddr).share()).transferFrom(address(escrow), receiver, shares),
                "InvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    // --- Helpers ---
    /// @dev    Calculates share amount based on asset amount and share price. Returned value is in share decimals.
    function _calculateShares(uint128 assets, address vaultAddr, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        if (price == 0 || assets == 0) {
            shares = 0;
        } else {
            (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vaultAddr);

            uint256 sharesInPriceDecimals =
                _toPriceDecimals(assets, assetDecimals).mulDiv(10 ** PRICE_DECIMALS, price, rounding);

            shares = _fromPriceDecimals(sharesInPriceDecimals, shareDecimals);
        }
    }

    /// @dev    Calculates asset amount based on share amount and share price. Returned value is in asset decimals.
    function _calculateAssets(uint128 shares, address vaultAddr, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 assets)
    {
        if (price == 0 || shares == 0) {
            assets = 0;
        } else {
            (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vaultAddr);

            uint256 assetsInPriceDecimals =
                _toPriceDecimals(shares, shareDecimals).mulDiv(price, 10 ** PRICE_DECIMALS, rounding);

            assets = _fromPriceDecimals(assetsInPriceDecimals, assetDecimals);
        }
    }

    /// @dev    Calculates share price and returns the value in price decimals
    function _calculatePrice(address vaultAddr, uint128 assets, uint128 shares) internal view returns (uint256) {
        if (assets == 0 || shares == 0) {
            return 0;
        }

        (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vaultAddr);
        return _toPriceDecimals(assets, assetDecimals).mulDiv(
            10 ** PRICE_DECIMALS, _toPriceDecimals(shares, shareDecimals), MathLib.Rounding.Down
        );
    }

    /// @dev    When converting assets to shares using the price,
    ///         all values are normalized to PRICE_DECIMALS
    function _toPriceDecimals(uint128 _value, uint8 decimals) internal pure returns (uint256) {
        if (PRICE_DECIMALS == decimals) return uint256(_value);
        return uint256(_value) * 10 ** (PRICE_DECIMALS - decimals);
    }

    /// @dev    Converts decimals of the value from the price decimals back to the intended decimals
    function _fromPriceDecimals(uint256 _value, uint8 decimals) internal pure returns (uint128) {
        if (PRICE_DECIMALS == decimals) return _value.toUint128();
        return (_value / 10 ** (PRICE_DECIMALS - decimals)).toUint128();
    }

    /// @dev    Returns the asset decimals and the share decimals for a given vault
    function _getPoolDecimals(address vaultAddr) internal view returns (uint8 assetDecimals, uint8 shareDecimals) {
        assetDecimals = IERC20Metadata(IERC7540Vault(vaultAddr).asset()).decimals();
        shareDecimals = IERC20Metadata(IERC7540Vault(vaultAddr).share()).decimals();
    }

    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have to both pass
    ///         the restrictions for a successful share transfer.
    function _canTransfer(address vaultAddr, address from, address to, uint256 value) internal view returns (bool) {
        ITranche share = ITranche(IERC7540Vault(vaultAddr).share());
        return share.checkTransferRestriction(from, to, value);
    }

    /// @inheritdoc IInvestmentManager
    function vaultByAddress(uint64 poolId, bytes16 trancheId, address asset) public view returns (address) {
        return vault[poolId][trancheId][poolManager.assetToId(asset)];
    }
}

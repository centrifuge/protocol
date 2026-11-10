// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./interfaces/IAsyncVault.sol";
import "./policies/interfaces/IVaultPlugins.sol";
import {BucketLib} from "./libraries/BucketLib.sol";
import {HorizonLib} from "./libraries/HorizonLib.sol";
import "./messaging/interfaces/IVaultRequestManager.sol";
import {VaultPricingLib} from "./libraries/VaultPricingLib.sol";
import {IVaultOracle} from "./oracles/interfaces/IVaultOracle.sol";
import {VaultRequestIdLib} from "./libraries/VaultRequestIdLib.sol";
import {VaultActionLib, VaultActionKind, VaultAction} from "./libraries/VaultActionLib.sol";

import {D18} from "../misc/types/D18.sol";
import {Auth, IAuth} from "../misc/Auth.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IERC20Metadata} from "../misc/interfaces/IERC20.sol";
import {IERC7575, IERC165} from "../misc/interfaces/IERC7575.sol";
import {ReentrancyProtection} from "../misc/ReentrancyProtection.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";
import {IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "../misc/interfaces/IERC7540.sol";
import {IERC8161DepositTransferable, IERC8161RedeemTransferable} from "../misc/interfaces/IERC8161.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {RequestId} from "../core/types/RequestId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IEscrow} from "../core/spoke/interfaces/IEscrow.sol";
import {ISpokeRegistry, VaultDetails} from "../core/spoke/interfaces/ISpokeRegistry.sol";

import {IShareToken} from "../token/interfaces/IShareToken.sol";

/// @title  Vault
/// @notice One immutable vault per (pool, share class, asset, variant), serving two lanes on one share
///         token: instant (ERC-4626) at the oracle's prices, sized and priced by the instant policy; and
///         async (ERC-7540) requests, bucketed by the request policy, sent through the pool's request
///         manager and settled pro-rata into a per-controller claimable ledger. Also ERC-7575 and ERC-8161.
///         Extension points: the six VDK plugins, the five slots of `VaultPlugins` and the share token's
///         `IRoleHook`. Assets and shares rest in the escrow, never here.
contract Vault is Auth, Recoverable, ReentrancyProtection, IAsyncVault {
    using MathLib for *;
    using BucketLib for BucketLib.State;
    using HorizonLib for HorizonLib.State;
    using VaultRequestIdLib for RequestId;

    // Identity
    address public immutable asset;
    PoolId public immutable poolId;
    address public immutable share;
    AssetId public immutable assetId;
    ShareClassId public immutable scId;
    uint8 internal immutable _shareDecimals;
    uint8 internal immutable _assetDecimals;

    // Protocol dependencies
    ISpoke public immutable spoke;
    address public immutable escrow;
    ISpokeRegistry public immutable spokeRegistry;

    // VDK plugins
    IVaultOracle public immutable oracle;
    IInstantPolicy public immutable instantPolicy;
    IRequestPolicy public immutable requestPolicy;
    ILiquidityRoute public immutable liquidityRoute;
    ISettlementObserver public immutable settlementObserver;

    // Fold horizon
    bool internal immutable _isBatched;
    uint256 public immutable foldHorizon;
    uint256 internal immutable _giftSlots;
    bool internal immutable _supportsTransfers;

    // Investor state
    mapping(address investor => InvestmentState) internal _investments;
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    // Async settlement
    uint64 internal _lastLocalId;
    uint64 internal _lastRedeemBatch;
    uint64 internal _lastDepositBatch;
    BucketLib.State internal _buckets;
    HorizonLib.State internal _horizon;
    mapping(uint96 localId => bytes32) public keyOf;
    /// @dev Both sides' bucket per key in one slot, deposit in the low 96 bits: the second side rewrites it.
    mapping(bytes32 key => uint256) internal _bucketIds;

    constructor(
        PoolId poolId_,
        ShareClassId scId_,
        address asset_,
        AssetId assetId_,
        IShareToken token,
        VaultConfig memory config
    ) Auth(msg.sender) {
        poolId = poolId_;
        scId = scId_;
        asset = asset_;
        assetId = assetId_;
        share = address(token);
        _shareDecimals = IERC20Metadata(address(token)).decimals();
        _assetDecimals = IERC20Metadata(asset_).decimals();

        spoke = config.spoke;
        escrow = address(config.spoke.escrow(poolId_));
        spokeRegistry = config.spokeRegistry;
        oracle = config.plugins.oracle;
        instantPolicy = config.plugins.instantPolicy;
        requestPolicy = config.plugins.requestPolicy;
        liquidityRoute = config.plugins.liquidityRoute;
        settlementObserver = config.plugins.settlementObserver;
        (uint256 horizon, uint256 open, bool batches) = _readRequestPolicy(config);
        foldHorizon = horizon;
        _isBatched = batches;
        _giftSlots = horizon + 1 - open;
        _supportsTransfers = address(requestPolicy) != address(0) && requestPolicy.supportsTransfers();
    }

    modifier linked() {
        _requireLinked();
        _;
    }

    modifier onlyController(address controller) {
        _requireController(controller);
        _;
    }

    modifier onlyRequestManager() {
        _requireRequestManager();
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Requests
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        linked
        nonReentrant
        returns (uint256 requestId)
    {
        require(_actsFor(owner), InvalidOwner());

        uint128 assets_ = assets.toUint128();
        require(assets_ != 0, ZeroAmount());
        _requireCredit(owner, controller);
        _enforceAction(
            VaultAction(
                VaultActionKind.DepositRequest, controller, owner, controller, assets_, _sharesEstimate(assets_)
            )
        );

        uint96 localId = _registerRequest(controller, owner, assets_, true);

        // Escrowed and reserved per request before the flush, so a manager settling inside it finds the
        // assets in place. The note and reserve cancel, so the deposit is not hub-accounted until approval.
        SafeTransferLib.safeTransferFrom(asset, owner, escrow, assets);
        spoke.noteDeposit(poolId, scId, asset, 0, assets_);
        spoke.reserve(poolId, scId, asset, 0, assets_, address(this), _depositReason(localId));

        requestId = VaultRequestIdLib.ofThis(localId);
        emit IERC7540Deposit.DepositRequest(controller, owner, requestId, msg.sender, assets);
        if (!_isBatched) _flushRequest(localId);
    }

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        linked
        nonReentrant
        returns (uint256 requestId)
    {
        uint128 shares_ = shares.toUint128();
        require(shares_ != 0, ZeroAmount());
        // `owner` is not validated yet, so a sponsor can be named as `owner` and pass the credit check; pulling its
        // shares below still needs its allowance or operator status
        _requireCredit(owner, controller);
        _enforceAction(
            VaultAction(VaultActionKind.RedeemRequest, controller, owner, address(0), _assetsEstimate(shares_), shares_)
        );

        uint96 localId = _registerRequest(controller, owner, shares_, false);

        // Operator of owner: transfer as the owner to bypass the allowance check.
        address sender = owner != msg.sender && _actsFor(owner) ? owner : msg.sender;
        spoke.transferSharesFrom(poolId, scId, sender, owner, escrow, shares_);

        requestId = VaultRequestIdLib.ofThis(localId);
        emit IERC7540Redeem.RedeemRequest(controller, owner, requestId, msg.sender, shares);
        if (!_isBatched) _flushRequest(localId);
    }

    /// @inheritdoc IERC8161DepositTransferable
    function transferDepositRequest(uint256 requestId, address oldController, address newController)
        external
        linked
        nonReentrant
        onlyController(oldController)
    {
        _transferRequest(requestId, oldController, newController, true);
        emit TransferDepositRequest(requestId, oldController, newController, msg.sender);
    }

    /// @inheritdoc IERC8161RedeemTransferable
    function transferRedeemRequest(uint256 requestId, address oldController, address newController)
        external
        linked
        nonReentrant
        onlyController(oldController)
    {
        _transferRequest(requestId, oldController, newController, false);
        emit TransferRedeemRequest(requestId, oldController, newController, msg.sender);
    }

    /// @inheritdoc IVaultBase
    function flushRequest(uint96 localId) external nonReentrant {
        require(!_isBatched || requestPolicy.isClosed(address(this), keyOf[localId]), BucketStillOpen());
        _flushRequest(localId);
    }

    /// @inheritdoc IAsyncVault
    /// @dev A position with nothing left to fold (already folded and completed, or never there) is a no-op, so a
    ///      keeper batch is not broken by a claim or a settlement's fold landing first.
    function foldRequest(uint96 localId, address controller) external nonReentrant {
        if (_buckets.contributions[localId][controller].amount == 0) return;
        _foldPosition(localId, controller);
    }

    //----------------------------------------------------------------------------------------------
    // Claims
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Deposit
    /// @dev A claim only: with nothing claimable it reverts, so a retried claim never becomes a new trade. The
    ///      instant lane is the 2-argument form.
    function deposit(uint256 assets, address receiver, address controller)
        external
        nonReentrant
        onlyController(controller)
        returns (uint256)
    {
        _foldHorizon(controller);
        return _claimDeposit(assets.toUint128(), receiver, controller);
    }

    /// @inheritdoc IERC7575
    /// @dev Instant when the caller has nothing claimable or pending, a claim otherwise.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256) {
        uint128 amount = assets.toUint128();
        _foldHorizon(msg.sender);
        if (_isInstant(msg.sender, true)) return _instantDeposit(amount, receiver);

        return _claimDeposit(amount, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev A claim only, like the 3-argument `deposit`.
    function mint(uint256 shares, address receiver, address controller)
        external
        nonReentrant
        onlyController(controller)
        returns (uint256)
    {
        _foldHorizon(controller);
        return _claimMint(shares.toUint128(), receiver, controller);
    }

    /// @inheritdoc IERC7575
    /// @dev Instant when the caller has nothing claimable or pending, a claim otherwise.
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256) {
        uint128 amount = shares.toUint128();
        _foldHorizon(msg.sender);
        if (_isInstant(msg.sender, true)) return _instantMint(amount, receiver);

        return _claimMint(amount, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    /// @dev Instant when the caller is the owner, as ERC-4626 requires; for an operator, a claim only.
    function withdraw(uint256 assets, address receiver, address controller)
        public
        nonReentrant
        onlyController(controller)
        returns (uint256)
    {
        uint128 amount = assets.toUint128();
        _foldHorizon(controller);
        if (_isInstant(controller, false)) return _instantWithdraw(amount, receiver);

        return _claimWithdraw(amount, receiver, controller);
    }

    /// @inheritdoc IVaultTwoArgClaims
    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        return withdraw(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    /// @dev Instant when the caller is the owner, as ERC-4626 requires; for an operator, a claim only.
    function redeem(uint256 shares, address receiver, address controller)
        public
        nonReentrant
        onlyController(controller)
        returns (uint256)
    {
        uint128 amount = shares.toUint128();
        _foldHorizon(controller);
        if (_isInstant(controller, false)) return _instantRedeem(amount, receiver);

        return _claimRedeem(amount, receiver, controller);
    }

    /// @inheritdoc IVaultTwoArgClaims
    function redeem(uint256 shares, address receiver) external returns (uint256) {
        return redeem(shares, receiver, msg.sender);
    }

    //----------------------------------------------------------------------------------------------
    // Settlement callbacks
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultDepositCallbacks
    function approveDeposits(uint96 localId, uint128 assetAmount) external onlyRequestManager {
        _forwardToRoute(VaultRequestIdLib.ofThis(localId), _releaseDeposit(localId, assetAmount));
    }

    /// @inheritdoc IVaultDepositCallbacks
    /// @dev Shares parked in the escrow for claiming carry no holding accounting.
    function issueShares(uint96, uint128 shareAmount) external onlyRequestManager {
        spoke.issue(poolId, scId, escrow, shareAmount);
    }

    /// @inheritdoc IVaultDepositCallbacks
    function fulfillDepositRequest(uint96 localId, uint128 assetAmount, uint128 shareAmount)
        external
        onlyRequestManager
    {
        _settle(localId, true, Settlement(assetAmount, shareAmount, 0, 0));
    }

    /// @inheritdoc IVaultDepositCallbacks
    function cancelDeposit(uint96 localId, uint128 grossAssetAmount, uint128 netAssetAmount)
        external
        onlyRequestManager
    {
        _cancel(localId, true, grossAssetAmount, netAssetAmount);
    }

    /// @inheritdoc IVaultRedeemCallbacks
    function revokeShares(uint96, uint128 assetAmount, uint128 shareAmount) external onlyRequestManager {
        _reservePayout(assetAmount);
        _revoke(escrow, shareAmount);
    }

    /// @inheritdoc IVaultRedeemCallbacks
    function fulfillRedeemRequest(uint96 localId, uint128 assetAmount, uint128 shareAmount)
        external
        onlyRequestManager
    {
        _settle(localId, false, Settlement(assetAmount, shareAmount, 0, 0));
    }

    /// @inheritdoc IVaultRedeemCallbacks
    function cancelRedeem(uint96 localId, uint128 grossShareAmount, uint128 netShareAmount)
        external
        onlyRequestManager
    {
        _cancel(localId, false, grossShareAmount, netShareAmount);
    }

    //----------------------------------------------------------------------------------------------
    // Views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        return _pendingRequest(requestId, controller, true);
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return _pendingRequest(requestId, controller, false);
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        (assets,) = _claimableDeposit(controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        (, shares) = _claimableRedeem(controller);
    }

    /// @inheritdoc IERC7575
    function maxDeposit(address controller) external view returns (uint256) {
        (bool isAsync, uint128 filled,, uint128 assets) = _depositLedger(controller);
        if (isAsync) return filled != 0 && _canFillDeposit(controller, filled, assets) ? assets : 0;
        if (!_isLinked()) return 0;

        (D18 ppa, D18 pps, bool valid) = _prices();
        (uint128 capacity,) = _maxInstantDeposit(controller, ppa, pps, valid);
        return capacity;
    }

    /// @inheritdoc IERC7575
    function maxMint(address controller) external view returns (uint256) {
        (bool isAsync, uint128 filled, uint128 refund, uint128 assets) = _depositLedger(controller);
        if (isAsync) return _maxClaimMint(controller, filled, refund, assets);
        if (!_isLinked()) return 0;

        (D18 ppa, D18 pps, bool valid) = _prices();
        (, uint128 shares_) = _maxInstantDeposit(controller, ppa, pps, valid);
        return shares_;
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) external view returns (uint256) {
        return _maxWithdraw(controller, true);
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) external view returns (uint256) {
        (bool isAsync, uint128 filled,, uint128 shares) = _redeemLedger(controller);
        if (isAsync) return filled != 0 && _canFillRedeem(controller, filled, shares) ? shares : 0;
        if (!_isLinked()) return 0;

        (D18 ppa, D18 pps, bool valid) = _prices();
        uint128 gross = _maxInstantRedeem(controller, true, ppa, pps, valid, MathLib.Rounding.Down);
        if (gross == 0) return 0;

        // A capacity whose shares convert back to no assets is not one: the redeem reverts, so the view reports none.
        uint128 shares_ = _toShares(gross, ppa, pps, MathLib.Rounding.Down);
        uint128 value = _toAssets(shares_, ppa, pps, MathLib.Rounding.Down);
        return value == 0 || _quotedSpread(false, controller, value, false) >= value ? 0 : shares_;
    }

    /// @inheritdoc IAsyncVault
    function withdrawCapacity(address owner) external view returns (uint256) {
        return _maxWithdraw(owner, false);
    }

    /// @inheritdoc IERC7575
    /// @dev What the 2-argument call would do for the caller: the instant quote, or, for a caller with a claim, the
    ///      claim's pro-rata. The views of a caller in async mode need no price, so they hold while the oracle is
    ///      paused. `convertTo*` do not depend on the caller.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        uint128 assets_ = assets.toUint128();
        (bool isAsync, uint128 filled,, uint128 claimable) = _depositLedger(msg.sender);
        if (isAsync) {
            require(claimable != 0, ExceedsDepositLimits());
            return filled.fractionOf(assets_, claimable, MathLib.Rounding.Down);
        }

        uint128 netAssets = assets_ - _quotedSpread(true, msg.sender, assets_, false);
        (D18 ppa, D18 pps) = _pricesChecked();
        return _toShares(netAssets, ppa, pps, MathLib.Rounding.Down);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256) {
        uint128 shares_ = shares.toUint128();
        (bool isAsync, uint128 filled, uint128 refund, uint128 claimable) = _depositLedger(msg.sender);
        if (isAsync) {
            // Refunded shares carry no assets, so only the filled part is priced
            uint128 priced = shares_ - MathLib.min(shares_, refund).toUint128();
            if (priced == 0) return 0;
            require(filled != 0, ExceedsDepositLimits());
            return claimable.fractionOf(priced, filled, MathLib.Rounding.Up);
        }

        (D18 ppa, D18 pps) = _pricesChecked();
        uint128 netAssets = _toAssets(shares_, ppa, pps, MathLib.Rounding.Up);
        return netAssets + _quotedSpread(true, msg.sender, netAssets, true);
    }

    /// @inheritdoc IERC7575
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint128 assets_ = assets.toUint128();
        (bool isAsync, uint128 filled, uint128 refund, uint128 claimableShares) = _redeemLedger(msg.sender);
        if (isAsync) {
            // Refunded assets carry no shares, so only the filled part is priced
            uint128 priced = assets_ - MathLib.min(assets_, refund).toUint128();
            if (priced == 0) return 0;
            require(filled != 0, ExceedsRedeemLimits());
            return claimableShares.fractionOf(priced, filled, MathLib.Rounding.Up);
        }

        uint128 gross = assets_ + _quotedSpread(false, msg.sender, assets_, true);
        (D18 ppa, D18 pps) = _pricesChecked();
        return _toShares(gross, ppa, pps, MathLib.Rounding.Up);
    }

    /// @inheritdoc IERC7575
    function previewRedeem(uint256 shares) external view returns (uint256) {
        uint128 shares_ = shares.toUint128();
        (bool isAsync, uint128 filled,, uint128 claimableShares) = _redeemLedger(msg.sender);
        if (isAsync) {
            require(claimableShares != 0, ExceedsRedeemLimits());
            return filled.fractionOf(shares_, claimableShares, MathLib.Rounding.Down);
        }

        (D18 ppa, D18 pps) = _pricesChecked();
        uint128 gross = _toAssets(shares_, ppa, pps, MathLib.Rounding.Down);
        return gross - _quotedSpread(false, msg.sender, gross, false);
    }

    /// @inheritdoc IERC7575
    function convertToShares(uint256 assets) external view returns (uint256) {
        (D18 ppa, D18 pps,) = _prices();
        return pps.isZero() ? 0 : _toShares(assets.toUint128(), ppa, pps, MathLib.Rounding.Down);
    }

    /// @inheritdoc IERC7575
    function convertToAssets(uint256 shares) public view returns (uint256) {
        (D18 ppa, D18 pps,) = _prices();
        return ppa.isZero() ? 0 : _toAssets(shares.toUint128(), ppa, pps, MathLib.Rounding.Down);
    }

    /// @inheritdoc IERC7575
    function totalAssets() external view returns (uint256) {
        return convertToAssets(IERC20Metadata(share).totalSupply());
    }

    /// @inheritdoc IAsyncVault
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** _shareDecimals);
    }

    /// @inheritdoc IVaultBase
    function claimableMint(address controller) external view returns (uint256 shares) {
        (, shares) = _claimableDeposit(controller);
    }

    /// @inheritdoc IVaultBase
    function claimableWithdraw(address controller) external view returns (uint256 assets) {
        (assets,) = _claimableRedeem(controller);
    }

    /// @inheritdoc IVaultBase
    function bucket(uint96 localId) external view returns (Bucket memory) {
        return _buckets.buckets[localId];
    }

    /// @inheritdoc IVaultBase
    function bucketOf(bytes32 key, bool isDeposit) public view returns (uint96) {
        return uint96(_bucketIds[key] >> (isDeposit ? 0 : 96));
    }

    /// @inheritdoc IVaultBase
    function contribution(uint96 localId, address controller) external view returns (Contribution memory) {
        return _buckets.contributions[localId][controller];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (
            interfaceId == type(IERC7575).interfaceId || interfaceId == type(IERC165).interfaceId
                || interfaceId == type(IERC7540Operator).interfaceId
        ) return true;

        if (address(requestPolicy) == address(0)) return false;
        if (interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId) {
            return true;
        }

        return (interfaceId == type(IERC8161DepositTransferable).interfaceId
                || interfaceId == type(IERC8161RedeemTransferable).interfaceId) && _supportsTransfers;
    }

    //----------------------------------------------------------------------------------------------
    // Internal: async lane
    //----------------------------------------------------------------------------------------------

    function _claimDeposit(uint128 amount, address receiver, address controller) internal returns (uint256) {
        require(amount != 0, ZeroAmount());
        InvestmentState storage state = _investments[controller];
        uint128 claimable = state.depositAssets;
        require(amount <= claimable, ExceedsDepositLimits());
        uint128 shares_ = state.depositShares.fractionOf(amount, claimable, MathLib.Rounding.Down).toUint128();
        require(shares_ != 0, ZeroAmount());

        _enforceDelivery(controller, receiver, amount, shares_, 0);
        state.depositAssets = claimable - amount;
        state.depositShares -= shares_;
        _deliverShares(controller, receiver, shares_, 0);
        emit IERC7575.Deposit(controller, receiver, amount, shares_);
        emit Claimed(controller, receiver, msg.sender, true, amount, shares_, 0);
        return shares_;
    }

    /// @dev Takes refunded shares first, which carry no assets, then filled ones pro-rata. Refunds alone emit
    ///      `Deposit` with zero assets, which `Claimed.refund` tells from a free trade.
    function _claimMint(uint128 amount, address receiver, address controller) internal returns (uint256) {
        require(amount != 0, ZeroAmount());
        InvestmentState storage state = _investments[controller];
        uint128 refund = MathLib.min(amount, state.refundShares).toUint128();
        uint128 filled = amount - refund;
        uint128 claimable = state.depositShares;
        require(filled <= claimable, ExceedsDepositLimits());
        uint128 assets_ = state.depositAssets.fractionOf(filled, claimable, MathLib.Rounding.Up).toUint128();

        _enforceDelivery(controller, receiver, assets_, amount, refund);
        if (refund != 0) state.refundShares -= refund;
        state.depositShares = claimable - filled;
        state.depositAssets -= assets_;
        _deliverShares(controller, receiver, amount, refund);
        emit IERC7575.Deposit(controller, receiver, assets_, amount);
        emit Claimed(controller, receiver, msg.sender, true, assets_, amount, refund);
        return assets_;
    }

    /// @dev Takes refunded assets first, which no shares were redeemed for, then filled ones pro-rata. Refunds
    ///      alone emit `Withdraw` with zero shares, which `Claimed.refund` tells from a free trade.
    function _claimWithdraw(uint128 amount, address receiver, address controller) internal returns (uint256) {
        require(amount != 0, ZeroAmount());
        InvestmentState storage state = _investments[controller];
        uint128 refund = MathLib.min(amount, state.refundAssets).toUint128();
        uint128 filled = amount - refund;
        uint128 claimable = state.redeemAssets;
        require(filled <= claimable, ExceedsRedeemLimits());
        uint128 shares_ = state.redeemShares.fractionOf(filled, claimable, MathLib.Rounding.Up).toUint128();

        _payRedeem(controller, receiver, amount, shares_, refund);
        emit IERC7575.Withdraw(msg.sender, receiver, controller, amount, shares_);
        emit Claimed(controller, receiver, msg.sender, false, amount, shares_, refund);
        return shares_;
    }

    function _claimRedeem(uint128 amount, address receiver, address controller) internal returns (uint256) {
        require(amount != 0, ZeroAmount());
        InvestmentState storage state = _investments[controller];
        uint128 claimable = state.redeemShares;
        require(amount <= claimable, ExceedsRedeemLimits());
        uint128 assets_ = state.redeemAssets.fractionOf(amount, claimable, MathLib.Rounding.Down).toUint128();
        require(assets_ != 0, ZeroAmount());

        _payRedeem(controller, receiver, assets_, amount, 0);
        emit IERC7575.Withdraw(msg.sender, receiver, controller, assets_, amount);
        emit Claimed(controller, receiver, msg.sender, false, assets_, amount, 0);
        return assets_;
    }

    /// @dev The policy names a bucket by a key of its own, and the vault allocates the ids: the first request under a
    ///      key opens a bucket and later ones join it, while a zero key opens a fresh bucket every time.
    function _registerRequest(address controller, address owner, uint128 amount, bool isDeposit)
        internal
        returns (uint96 localId)
    {
        require(controller != address(0), InvalidController());
        bytes32 key = requestPolicy.onRequest(address(this), controller, owner, isDeposit, amount);
        uint96 joined = key != 0 ? bucketOf(key, isDeposit) : 0;
        localId = joined != 0 ? joined : _openBucket(key, isDeposit);

        _buckets.contribute(localId, controller, isDeposit, amount, _isBatched, key);
        _addToHorizon(controller, localId, isDeposit, owner == controller || _actsFor(controller));
    }

    /// @dev A batching vault's new batch on a side also sends the side's previous one, once its policy reports it
    ///      closed and it holds queued requests; a batch that is still open then waits for `flushRequest`. A batch
    ///      needs a key, which is what `isClosed` is asked about.
    function _openBucket(bytes32 key, bool isDeposit) internal returns (uint96 localId) {
        localId = ++_lastLocalId;
        if (key == 0) {
            require(!_isBatched, ZeroBatchKey());
            return localId;
        }

        _bucketIds[key] |= uint256(localId) << (isDeposit ? 0 : 96);
        keyOf[localId] = key;
        if (!_isBatched) return localId;

        uint96 previous = isDeposit ? _lastDepositBatch : _lastRedeemBatch;
        if (isDeposit) _lastDepositBatch = _lastLocalId;
        else _lastRedeemBatch = _lastLocalId;
        if (_buckets.buckets[previous].queued != 0 && requestPolicy.isClosed(address(this), keyOf[previous])) {
            _flushRequest(previous);
        }
    }

    function _flushRequest(uint96 localId) internal {
        (uint128 amount, bool isDeposit) = _buckets.flush(localId);

        // Emitted first: a same-chain manager can settle the bucket inside the send, and its events follow.
        emit RequestFlushed(VaultRequestIdLib.ofThis(localId), isDeposit, amount);
        IVaultRequestManager manager = IVaultRequestManager(address(spokeRegistry.requestManager(poolId)));
        if (isDeposit) manager.sendDepositRequest(localId, amount);
        else manager.sendRedeemRequest(localId, amount);
    }

    /// @dev A position the controller did not submit or fund (`own` is false) takes a free slot only, and never one of
    ///      those kept for the controller's open buckets, so it never evicts one of theirs and an own request never
    ///      has to evict an open one; when none is free a batch waits for `foldRequest`.
    function _addToHorizon(address controller, uint96 localId, bool isDeposit, bool own) internal {
        _horizon.add(
            _buckets, _investments[controller], controller, localId, isDeposit, own, own ? foldHorizon : _giftSlots
        );
    }

    function _transferRequest(uint256 requestId, address oldController, address newController, bool isDeposit)
        internal
    {
        require(_supportsTransfers, TransfersUnsupported());
        RequestId rid = RequestId.wrap(requestId);
        require(rid.vaultOf() == address(this), InvalidRequestId());
        uint96 localId = rid.localIdOf();

        // `total != 0` rejects a local id that names no bucket; the side check alone would not.
        Bucket storage b = _buckets.buckets[localId];
        require(b.total != 0 && b.isDeposit == isDeposit, InvalidRequestId());
        _requireCredit(oldController, newController);

        // Fold the sender out so only their unsettled remainder moves, then gate it through the hook.
        _foldPosition(localId, oldController);
        uint128 amount = _buckets.pendingNow(localId, oldController);
        (uint128 assets_, uint128 shares_) =
            isDeposit ? (amount, _sharesEstimate(amount)) : (_assetsEstimate(amount), amount);
        _enforceAction(
            VaultAction(
                isDeposit ? VaultActionKind.DepositRequestTransfer : VaultActionKind.RedeemRequestTransfer,
                oldController,
                oldController,
                newController,
                assets_,
                shares_
            )
        );

        uint128 contributed = _buckets.transfer(localId, oldController, newController);
        if (!_isBatched) _releaseKey(localId, isDeposit);
        _horizon.remove(_buckets, oldController, localId, isDeposit);
        // A position moved in is never one of the recipient's open buckets, so it fills only a free slot
        _addToHorizon(newController, localId, isDeposit, false);
        emit RequestTransferred(requestId, oldController, newController, isDeposit, contributed, amount);
    }

    /// @dev An unbatched bucket's key is its owner's, so once the bucket moves to another controller the key stops
    ///      naming it, and the sender's next request on the side opens a bucket of its own. `keyOf` keeps the key.
    function _releaseKey(uint96 localId, bool isDeposit) internal {
        bytes32 key = keyOf[localId];
        if (key == 0 || bucketOf(key, isDeposit) != localId) return;
        _bucketIds[key] &= ~(uint256(type(uint96).max) << (isDeposit ? 0 : 96));
    }

    /// @dev Request id 0 is the ERC-7540 aggregate over the open buckets; any other id names one.
    function _pendingRequest(uint256 requestId, address controller, bool isDeposit) internal view returns (uint256) {
        if (requestId == 0) {
            UnfoldedState memory u = _unfolded(controller);
            return isDeposit ? u.depositPending : u.redeemPending;
        }

        RequestId rid = RequestId.wrap(requestId);
        if (rid.vaultOf() != address(this)) return 0;
        uint96 localId = rid.localIdOf();

        // An unused bucket reads as an empty deposit bucket, so an unknown id answers zero either way.
        if (_buckets.buckets[localId].isDeposit != isDeposit) return 0;
        return _horizon.pendingReported(_buckets, localId, controller);
    }

    /// @dev Instant only for the caller's own position, with nothing claimable and nothing pending on that side. The
    ///      instant path takes the caller's assets or burns the caller's shares, so an operator never reaches it.
    function _isInstant(address controller, bool isDeposit) internal view returns (bool) {
        if (controller != msg.sender) return false;

        InvestmentState storage state = _investments[controller];
        uint128 claimable = isDeposit
            ? MathLib.saturatingAdd(state.depositShares, state.refundShares)
            : MathLib.saturatingAdd(state.redeemAssets, state.refundAssets);
        return claimable == 0 && _buckets.sides[controller][isDeposit].pending == 0;
    }

    /// @dev Runs before the ledger is debited and any share moves, so a hook reading the position sees it whole.
    function _enforceDelivery(address controller, address receiver, uint128 assets, uint128 shares, uint128 refund)
        internal
    {
        uint128 refunded = receiver == controller ? refund : 0;
        if (refunded != 0) {
            _enforceAction(
                VaultAction(
                    VaultActionKind.RedeemRefundClaim,
                    controller,
                    address(0),
                    receiver,
                    _assetsEstimate(refunded),
                    refunded
                )
            );
        }
        if (shares > refunded) {
            // Refunded shares to another receiver ride on the claim, with their value beside the fill's
            uint128 value =
                refunded == 0 && refund != 0 ? MathLib.saturatingAdd(assets, _assetsEstimate(refund)) : assets;
            _enforceAction(
                VaultAction(VaultActionKind.DepositClaim, controller, address(0), receiver, value, shares - refunded)
            );
        }
    }

    /// @dev Refunded shares that return to the controller itself are shares it already held: they move by an
    ///      authorized transfer, which the share token's transfer hook does not see.
    function _deliverShares(address controller, address receiver, uint128 shares, uint128 refund) internal {
        uint128 refunded = receiver == controller ? refund : 0;
        if (refunded != 0) spoke.transferSharesFrom(poolId, scId, escrow, escrow, receiver, refunded);
        if (shares > refunded) spoke.withdrawShares(poolId, scId, receiver, shares - refunded);
    }

    /// @dev Gates the claim on the shares the payout was filled for, so `withdraw` and `redeem` check alike. A refund
    ///      to the controller itself is gated by `DepositRefundClaim` alone: a claim of refunds only asks nothing more.
    function _payRedeem(address controller, address receiver, uint128 assets, uint128 shares, uint128 refund) internal {
        uint128 refunded = receiver == controller ? refund : 0;
        if (refunded != 0) {
            _enforceAction(
                VaultAction(
                    VaultActionKind.DepositRefundClaim,
                    controller,
                    address(0),
                    receiver,
                    refunded,
                    _sharesEstimate(refunded)
                )
            );
        }
        // The payout is the assets the receiver gets, a refund to another receiver included
        if (assets > refunded || shares != 0) {
            _enforceAction(
                VaultAction(VaultActionKind.RedeemClaim, controller, address(0), receiver, assets - refunded, shares)
            );
        }

        InvestmentState storage state = _investments[controller];
        if (refund != 0) state.refundAssets -= refund;
        state.redeemAssets -= assets - refund;
        state.redeemShares -= shares;

        // The holding decrease was already queued when the payout was reserved in revokeShares.
        spoke.withdrawReserved(poolId, scId, asset, 0, receiver, assets, address(this), REASON_REDEEM);
    }

    /// @dev The views' reading of the deposit claim, with the horizon's unfolded slices included.
    function _claimableDeposit(address controller) internal view returns (uint128 assets, uint128 shares) {
        (, uint128 filled, uint128 refund, uint128 assets_) = _depositLedger(controller);
        return (assets_, MathLib.saturatingAdd(filled, refund));
    }

    /// @dev Redeem-side twin of `_claimableDeposit`; the exact unit is assets here.
    function _claimableRedeem(address controller) internal view returns (uint128 assets, uint128 shares) {
        (, uint128 filled, uint128 refund, uint128 shares_) = _redeemLedger(controller);
        return (MathLib.saturatingAdd(filled, refund), shares_);
    }

    /// @dev The deposit ledger with what folding the horizon would add, split the way a claim takes it: the filled
    ///      shares, the refunded shares, which carry no assets, and the assets the filled shares were bought with.
    function _depositLedger(address controller)
        internal
        view
        returns (bool isAsync, uint128 filled, uint128 refund, uint128 assets)
    {
        InvestmentState storage state = _investments[controller];
        UnfoldedState memory u = _unfolded(controller);
        filled = state.depositShares + u.depositShares;
        refund = state.refundShares + u.refundShares;
        assets = state.depositAssets + u.depositAssets;
        isAsync = filled != 0 || refund != 0 || u.depositPending != 0;
    }

    /// @dev Redeem-side twin of `_depositLedger`: the filled assets, the refunded assets, which no shares were
    ///      redeemed for, and the shares the filled assets were paid for.
    function _redeemLedger(address controller)
        internal
        view
        returns (bool isAsync, uint128 filled, uint128 refund, uint128 shares)
    {
        InvestmentState storage state = _investments[controller];
        UnfoldedState memory u = _unfolded(controller);
        filled = state.redeemAssets + u.redeemAssets;
        refund = state.refundAssets + u.refundAssets;
        shares = state.redeemShares + u.redeemShares;
        isAsync = filled != 0 || refund != 0 || u.redeemPending != 0;
    }

    /// @dev A claim takes the refund first, so a refused fill leaves the refund claimable and a refused refund nothing.
    function _maxClaimWithdraw(address controller, uint128 filled, uint128 refund, uint128 shares)
        internal
        view
        returns (uint128)
    {
        if (!_canRefund(VaultActionKind.DepositRefundClaim, controller, refund)) return 0;
        return _canFillRedeem(controller, filled, shares) ? MathLib.saturatingAdd(filled, refund) : refund;
    }

    /// @dev The deposit-side twin of `_maxClaimWithdraw`, for `mint`.
    function _maxClaimMint(address controller, uint128 filled, uint128 refund, uint128 assets)
        internal
        view
        returns (uint128)
    {
        if (!_canRefund(VaultActionKind.RedeemRefundClaim, controller, refund)) return 0;
        return _canFillDeposit(controller, filled, assets) ? MathLib.saturatingAdd(filled, refund) : refund;
    }

    function _canRefund(VaultActionKind kind, address controller, uint128 refund) internal view returns (bool) {
        if (refund == 0) return true;
        (uint128 assets, uint128 shares) = kind == VaultActionKind.DepositRefundClaim
            ? (refund, _sharesEstimate(refund))
            : (_assetsEstimate(refund), refund);
        return _isAllowed(VaultAction(kind, controller, address(0), controller, assets, shares));
    }

    function _canFillRedeem(address controller, uint128 filled, uint128 shares) internal view returns (bool) {
        return (filled == 0 && shares == 0)
            || _isAllowed(VaultAction(VaultActionKind.RedeemClaim, controller, address(0), controller, filled, shares));
    }

    function _canFillDeposit(address controller, uint128 filled, uint128 assets) internal view returns (bool) {
        return filled == 0
            || (IShareToken(share).checkTransferRestriction(escrow, controller, filled)
                && _isAllowed(
                VaultAction(VaultActionKind.DepositClaim, controller, address(0), controller, assets, filled)
            ));
    }

    /// @dev The bucket, `BucketSettled` and the observer all take the one `Settlement`, so they cannot disagree.
    function _settle(uint96 localId, bool isDeposit, Settlement memory s) internal {
        uint256 requestId = VaultRequestIdLib.ofThis(localId);
        _buckets.settle(localId, isDeposit, s.assets, s.shares, s.cancelledGross, s.cancelledNet);
        emit BucketSettled(requestId, isDeposit, s.assets, s.shares, s.cancelledGross, s.cancelledNet);
        // An unbatched bucket folds as it settles, so its claimable is current, its pending stops closing the instant
        // lane, and a completed one frees its id for reuse. A batch waits for its contributors' claims.
        address owner = _buckets.buckets[localId].owner;
        if (owner != address(0)) _foldPosition(localId, owner);
        if (address(settlementObserver) != address(0)) {
            settlementObserver.onSettle(address(this), requestId, isDeposit, s);
        }
    }

    /// @dev A cancelled deposit releases the full gross, since the net alone strands the rest; the retained fee on
    ///      either side accretes to NAV.
    function _cancel(uint96 localId, bool isDeposit, uint128 gross, uint128 net) internal {
        require(net <= gross, NetExceedsGross());
        if (isDeposit && gross > 0) _releaseDeposit(localId, gross);
        if (isDeposit && net > 0) _reservePayout(net);
        if (!isDeposit && gross > net) _revoke(escrow, gross - net);

        _settle(localId, isDeposit, Settlement(0, 0, gross, net));
    }

    /// @dev Per-request reservation key, so an early unlock and the approval settle the same request.
    function _depositReason(uint96 localId) internal pure returns (bytes32) {
        return keccak256(abi.encode(REASON_DEPOSIT, localId));
    }

    /// @dev Releases a deposit request's still-reserved portion into the holding, clamped: a manager may
    ///      have unlocked part early, and releasing more would revert and wedge the request.
    function _releaseDeposit(uint96 localId, uint128 amount) internal returns (uint128 release) {
        bytes32 reason = _depositReason(localId);
        release = MathLib.min(amount, IEscrow(escrow).reservedBy(scId, address(this), reason, asset, 0)).toUint128();
        if (release > 0) spoke.unreserve(poolId, scId, asset, 0, release, address(this), reason);
    }

    /// @dev A payout must be backed on top of what this vault already owes (pending deposits' cash counts),
    ///      else the callback reverts, retryable once the escrow is refunded.
    function _reservePayout(uint128 assets) internal {
        (uint128 total,) = IEscrow(escrow).holding(scId, asset, 0);
        uint128 owed = IEscrow(escrow).reservedBy(scId, address(this), REASON_REDEEM, asset, 0);
        require(total >= owed + assets, InsufficientLiquidity());
        spoke.reserve(poolId, scId, asset, 0, assets, address(this), REASON_REDEEM);
    }

    /// @dev A position the fold completes leaves the controller's horizon at once, so a later request reusing its id
    ///      enters afresh. The side is read first, since completing a sole owner's bucket deletes it.
    function _foldPosition(uint96 localId, address controller) internal {
        bool isDeposit = _buckets.buckets[localId].isDeposit;
        if (_buckets.foldInto(_investments[controller], localId, controller)) {
            _horizon.remove(_buckets, controller, localId, isDeposit);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Internal: instant lane, deposit
    //----------------------------------------------------------------------------------------------

    /// @dev The caller pays `escrowIn + charge - rebate`, and only `escrowIn - retained` backs the shares.
    function _instantDeposit(uint128 assets, address receiver) internal returns (uint128 shares) {
        _requireLinked();
        (D18 ppa, D18 pps) = _pricesChecked();
        require(assets != 0, ZeroAmount());
        require(assets <= _instantDepositCapacity(receiver, ppa, pps, true), ExceedsDepositLimits());

        InstantFee memory fee = _instantFee(true, receiver, assets, false);
        require(fee.charge < assets, ExceedsDepositLimits());

        // A rebate grows what the escrow receives, so the shares stay fully asset-backed.
        uint128 escrowIn = assets - fee.charge + fee.rebate;
        require(fee.retained < escrowIn, ExceedsDepositLimits());

        // The retained leg reaches the escrow but backs no shares, so it accrues to existing holders.
        shares = _toShares(escrowIn - fee.retained, ppa, pps, MathLib.Rounding.Down);
        require(shares > 0, ZeroAmount());

        _executeInstantDeposit(assets, escrowIn, shares, fee, receiver, ppa, pps);
    }

    function _instantMint(uint128 shares, address receiver) internal returns (uint128 assets) {
        _requireLinked();
        (D18 ppa, D18 pps) = _pricesChecked();
        uint128 backing = _toAssets(shares, ppa, pps, MathLib.Rounding.Up);
        require(backing > 0, ZeroAmount());

        InstantFee memory fee = _instantFee(true, receiver, backing, true);

        // The caller funds the shares' value plus the retained leg; only the former backs the shares.
        uint128 escrowIn = backing + fee.retained;
        assets = escrowIn + fee.charge - fee.rebate;
        require(assets <= _instantDepositCapacity(receiver, ppa, pps, true), ExceedsDepositLimits());

        _executeInstantDeposit(assets, escrowIn, shares, fee, receiver, ppa, pps);
    }

    /// @dev Issues before pulling the asset (CEI). The escrow receives exactly `escrowIn`: a charge is paid on top
    ///      by the caller, a rebate pulled from the fee source.
    function _executeInstantDeposit(
        uint128 assets,
        uint128 escrowIn,
        uint128 shares,
        InstantFee memory fee,
        address receiver,
        D18 ppa,
        D18 pps
    ) internal {
        _enforceAction(VaultAction(VaultActionKind.InstantDeposit, msg.sender, msg.sender, receiver, assets, shares));
        spoke.noteDeposit(poolId, scId, asset, 0, escrowIn);
        spoke.issue(poolId, scId, receiver, shares);

        if (fee.charge > 0) SafeTransferLib.safeTransferFrom(asset, msg.sender, fee.recipient, fee.charge);
        if (fee.rebate > 0) SafeTransferLib.safeTransferFrom(asset, fee.recipient, escrow, fee.rebate);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, escrow, escrowIn - fee.rebate);

        _forwardToRoute(0, escrowIn);
        emit IERC7575.Deposit(msg.sender, receiver, assets, shares);
        emit InstantFees(
            msg.sender,
            receiver,
            true,
            shares,
            fee.charge > 0 ? MathLib.toInt128(fee.charge) : -MathLib.toInt128(fee.rebate),
            fee.recipient,
            fee.retained,
            0,
            ppa,
            pps
        );
    }

    /// @dev Instant deposit capacity as the views report it, with the shares it issues: scaled down to what the hook
    ///      allows, and none where it would issue no shares, or the hook or the token would refuse the deposit.
    function _maxInstantDeposit(address receiver, D18 ppa, D18 pps, bool valid)
        internal
        view
        returns (uint128, uint128)
    {
        uint128 capacity = _instantDepositCapacity(receiver, ppa, pps, valid);
        if (capacity == 0) return (0, 0);
        capacity = _leaveRoomForRebate(receiver, capacity, ppa, pps);

        // A capacity that would issue no shares is not one: the deposit reverts, so the view reports none.
        (uint128 assets, uint128 shares_) = _scaleInstantDeposit(receiver, capacity, ppa, pps);
        if (shares_ == 0) return (0, 0);
        if (!_isAllowed(VaultAction(VaultActionKind.InstantDeposit, receiver, receiver, receiver, assets, shares_))) {
            return (0, 0);
        }
        if (!IShareToken(share).checkTransferRestriction(address(0), receiver, shares_)) return (0, 0);
        return (assets, shares_);
    }

    /// @dev `capacity` and its shares, scaled down to the hook's limits.
    function _scaleInstantDeposit(address receiver, uint128 capacity, D18 ppa, D18 pps)
        internal
        view
        returns (uint128, uint128)
    {
        uint128 shares_ = _instantDepositShares(receiver, capacity, ppa, pps);
        (uint256 maxAssets, uint256 maxShares) = VaultActionLib.limits(
            share, VaultAction(VaultActionKind.InstantDeposit, receiver, receiver, receiver, capacity, shares_)
        );

        // The deposit whose shares, net of the fee on top (less a rebate), are `maxShares`
        uint128 net = maxShares < shares_ ? _toAssets(uint128(maxShares), ppa, pps, MathLib.Rounding.Down) : 0;
        uint256 bound =
            maxShares < shares_ ? MathLib.min(maxAssets, _lessFee(true, receiver, net, true, true)) : maxAssets;
        if (bound >= capacity) return (capacity, shares_);

        // Rounding in the fee can issue past the limit; then the deposit of `net` with no fee on top, unless a rebate
        // still carries it past
        uint128 scaled = _instantDepositShares(receiver, uint128(bound), ppa, pps);
        if (scaled <= maxShares) return (uint128(bound), scaled);
        uint128 atNet = _instantDepositShares(receiver, net, ppa, pps);
        return atNet <= maxShares ? (net, atNet) : (0, 0);
    }

    /// @dev The shares `assets` buy at the signed fee, a rebate included, since the hook limits what is issued. A rebate
    ///      can carry the amount past what converts, so it is clamped to the `uint128` of shares first.
    function _instantDepositShares(address receiver, uint128 assets, D18 ppa, D18 pps) internal view returns (uint128) {
        uint128 net = VaultPricingLib.clampToShares(
            _lessFee(true, receiver, assets, false, false), _assetDecimals, _shareDecimals, ppa, pps, type(uint128).max
        );
        return _toShares(net, ppa, pps, MathLib.Rounding.Down);
    }

    /// @dev An invalid price reads as zero capacity, not capacity that reverts on use (ERC-4626 `max*`).
    function _instantDepositCapacity(address receiver, D18 ppa, D18 pps, bool valid) internal view returns (uint128) {
        if (!valid) return 0;
        if (address(instantPolicy) == address(0)) return 0;
        // The shares are issued on top of the supply, which holds at most a `uint128`
        uint256 room = type(uint128).max - IERC20Metadata(share).totalSupply();
        return VaultPricingLib.clampToShares(
            instantPolicy.maxInstantDeposit(address(this), receiver), _assetDecimals, _shareDecimals, ppa, pps, room
        );
    }

    /// @dev A rebate is converted on top of the deposit, so a deposit of the whole capacity can issue past the supply
    ///      room the capacity was clamped to; the views take the rebate's part back out.
    function _leaveRoomForRebate(address receiver, uint128 capacity, D18 ppa, D18 pps) internal view returns (uint128) {
        uint128 converted = _lessFee(true, receiver, capacity, false, false);
        if (converted <= capacity) return capacity;
        uint256 room = type(uint128).max - IERC20Metadata(share).totalSupply();
        uint128 fits = VaultPricingLib.clampToShares(converted, _assetDecimals, _shareDecimals, ppa, pps, room);
        return MathLib.saturatingSub(capacity, converted - fits);
    }

    //----------------------------------------------------------------------------------------------
    // Internal: instant lane, redeem
    //----------------------------------------------------------------------------------------------

    function _instantRedeem(uint128 shares, address receiver) internal returns (uint128 payout) {
        _requireLinked();
        (D18 ppa, D18 pps) = _pricesChecked();
        uint128 gross = _toAssets(shares, ppa, pps, MathLib.Rounding.Down);
        require(gross > 0, ZeroAmount());
        (uint128 capacity, uint128 escrowBalance) = _instantRedeemCapacity(msg.sender, ppa, pps, true);
        require(gross <= capacity, ExceedsRedeemLimits());

        InstantFee memory fee = _instantFee(false, receiver, gross, false);
        require(fee.charge < gross, ExceedsRedeemLimits());

        // The shares burn at their full value but the retained leg never leaves the escrow, so the difference
        // accrues to the holders who stayed.
        uint128 afterFee = gross - fee.charge + fee.rebate;
        require(fee.retained < afterFee, ExceedsRedeemLimits());
        payout = afterFee - fee.retained;

        _executeInstantRedeem(shares, payout, fee, receiver, escrowBalance, ppa, pps);
    }

    function _instantWithdraw(uint128 payout, address receiver) internal returns (uint128 shares) {
        _requireLinked();
        // Price before the (mutating) policy hook.
        (D18 ppa, D18 pps) = _pricesChecked();
        InstantFee memory fee = _instantFee(false, receiver, payout, true);

        // With a rebate, part of the payout is source-funded, so fewer shares are burned. The retained leg burns
        // extra shares whose value stays in the escrow.
        uint128 gross = payout + fee.retained + fee.charge - fee.rebate;
        (uint128 capacity, uint128 escrowBalance) = _instantRedeemCapacity(msg.sender, ppa, pps, true);
        require(gross <= capacity, ExceedsRedeemLimits());

        shares = _toShares(gross, ppa, pps, MathLib.Rounding.Up);
        require(shares > 0, ZeroAmount());

        _executeInstantRedeem(shares, payout, fee, receiver, escrowBalance, ppa, pps);
    }

    /// @dev Draws any escrow shortfall from the route, burns, then pays. A rebate is paid by the fee source
    ///      directly, outside pool accounting.
    function _executeInstantRedeem(
        uint128 shares,
        uint128 payout,
        InstantFee memory fee,
        address receiver,
        uint128 escrowBalance,
        D18 ppa,
        D18 pps
    ) internal {
        _enforceAction(VaultAction(VaultActionKind.InstantRedeem, msg.sender, msg.sender, receiver, payout, shares));
        uint128 escrowOut = payout + fee.charge - fee.rebate;
        uint128 routed = escrowOut > escrowBalance ? escrowOut - escrowBalance + _reservedBeyondTotal() : 0;
        if (routed != 0) _provideFromRoute(routed);

        _revoke(msg.sender, shares);

        spoke.withdraw(poolId, scId, asset, 0, receiver, payout - fee.rebate);
        if (fee.charge > 0) spoke.withdraw(poolId, scId, asset, 0, fee.recipient, fee.charge);
        if (fee.rebate > 0) SafeTransferLib.safeTransferFrom(asset, fee.recipient, receiver, fee.rebate);

        emit IERC7575.Withdraw(msg.sender, receiver, msg.sender, payout, shares);
        emit InstantFees(
            msg.sender,
            receiver,
            false,
            shares,
            fee.charge > 0 ? MathLib.toInt128(fee.charge) : -MathLib.toInt128(fee.rebate),
            fee.recipient,
            fee.retained,
            routed,
            ppa,
            pps
        );
    }

    /// @dev In assets before the exit fee, with the shares rounded as the entrypoint that follows the view rounds them.
    function _maxInstantRedeem(
        address owner,
        bool cappedAtBalance,
        D18 ppa,
        D18 pps,
        bool valid,
        MathLib.Rounding sharesRounding
    ) internal view returns (uint128) {
        (uint128 capacity,) = _instantRedeemCapacity(owner, ppa, pps, valid);
        // One share below the uint128 bound `_instantRedeemCapacity` already holds it to, so the conversion still
        // fits when it rounds up
        uint128 gross =
            VaultPricingLib.clampToShares(capacity, _assetDecimals, _shareDecimals, ppa, pps, type(uint128).max - 1);
        if (gross == 0) return 0;

        uint128 shares_ = _toShares(gross, ppa, pps, sharesRounding);
        uint128 capped =
            cappedAtBalance ? MathLib.min(shares_, IERC20Metadata(share).balanceOf(owner)).toUint128() : shares_;
        uint128 bound = _instantRedeemAllowed(owner, capped, ppa, pps);
        return bound < shares_ ? _toAssets(bound, ppa, pps, MathLib.Rounding.Down) : gross;
    }

    /// @dev How many of `shares` the hook allows an instant redemption of: scaled down to its limits, and none where
    ///      it would refuse the redemption at that amount.
    function _instantRedeemAllowed(address owner, uint128 shares, D18 ppa, D18 pps) internal view returns (uint128) {
        if (shares == 0) return 0;
        uint128 payout = _instantRedeemPayout(owner, shares, ppa, pps);
        (uint256 maxAssets, uint256 maxShares) = VaultActionLib.limits(
            share, VaultAction(VaultActionKind.InstantRedeem, owner, owner, owner, payout, shares)
        );

        uint256 limit =
            maxAssets < payout ? MathLib.min(maxShares, _sharesPaying(owner, uint128(maxAssets), ppa, pps)) : maxShares;
        uint128 allowed = limit < shares ? uint128(limit) : shares;
        if (allowed == 0) return 0;

        uint128 allowedPayout = allowed < shares ? _instantRedeemPayout(owner, allowed, ppa, pps) : payout;
        return _isAllowed(VaultAction(VaultActionKind.InstantRedeem, owner, owner, owner, allowedPayout, allowed))
            ? allowed
            : 0;
    }

    /// @dev Shares whose payout is at most `payout`. A fee comes out of the payout, so the shares `payout` converts to
    ///      bound it from below; a rebate adds to it, so their value is first taken down to the gross that pays `payout`.
    function _sharesPaying(address owner, uint128 payout, D18 ppa, D18 pps) internal view returns (uint128) {
        uint128 gross = MathLib.min(payout, _lessFee(false, owner, payout, true, true)).toUint128();
        return _toShares(gross, ppa, pps, MathLib.Rounding.Down);
    }

    /// @dev The payout at the signed fee, a rebate included, since the hook limits what is paid.
    function _instantRedeemPayout(address owner, uint128 shares, D18 ppa, D18 pps) internal view returns (uint128) {
        return _lessFee(false, owner, _toAssets(shares, ppa, pps, MathLib.Rounding.Down), false, false);
    }

    /// @dev What a manager has reserved beyond the escrow's total, which it may do ahead of arrival. Assets that
    ///      arrive meet that first, so a route's proceeds reach the unreserved balance only past it.
    function _reservedBeyondTotal() internal view returns (uint128) {
        (uint128 total, uint128 reserved) = IEscrow(escrow).holding(scId, asset, 0);
        return MathLib.saturatingSub(reserved, total);
    }

    /// @dev The policy cap bounded by the escrow plus any route, and the escrow balance read.
    function _instantRedeemCapacity(address owner, D18 ppa, D18 pps, bool valid)
        internal
        view
        returns (uint128 capacity, uint128 escrowBalance)
    {
        if (!valid) return (0, 0);
        if (address(instantPolicy) == address(0)) return (0, 0);

        escrowBalance = spoke.availableBalanceOf(poolId, scId, asset, 0);
        uint128 cap = instantPolicy.maxInstantRedeem(address(this), owner);
        uint256 reachable = escrowBalance;
        if (cap > escrowBalance && address(liquidityRoute) != address(0)) {
            reachable += MathLib.saturatingSub(liquidityRoute.available(address(this)), _reservedBeyondTotal());
        }
        capacity = VaultPricingLib.clampToConvertible(
            MathLib.min(cap, reachable).toUint128(), _assetDecimals, _shareDecimals, ppa, pps
        );
    }

    //----------------------------------------------------------------------------------------------
    // Internal: instant lane, fees and liquidity route
    //----------------------------------------------------------------------------------------------

    /// @dev Quotes before the policy records the trade, so the fee is the answer the previews gave.
    function _instantFee(bool isDeposit, address receiver, uint128 amount, bool exactOut)
        internal
        returns (InstantFee memory fee)
    {
        (int128 feeAssets, address recipient) = _quote(isDeposit, msg.sender, receiver, amount, exactOut);
        if (isDeposit) instantPolicy.onInstantDeposit(address(this), msg.sender, receiver, amount, exactOut);
        else instantPolicy.onInstantRedeem(address(this), msg.sender, receiver, amount, exactOut);
        require(feeAssets >= 0 || recipient != address(0), InvalidFeeRecipient());

        bool retained = recipient == address(0);
        fee = InstantFee({
            charge: feeAssets > 0 && !retained ? uint128(feeAssets) : 0,
            rebate: feeAssets < 0 ? uint128(-feeAssets) : 0,
            recipient: recipient,
            retained: feeAssets > 0 && retained ? uint128(feeAssets) : 0
        });
    }

    function _forwardToRoute(uint256 requestId, uint128 assets) internal {
        if (assets == 0 || address(liquidityRoute) == address(0)) return;
        emit ForwardedToRoute(address(liquidityRoute), requestId, assets);
        liquidityRoute.forward(address(this), assets);
    }

    /// @dev Draws `assets` from the route into the escrow and books them. Measured on this vault's balance, not
    ///      the shared escrow a reentrant route could fill via a sibling, so a route cannot pass off another
    ///      deposit as delivery.
    function _provideFromRoute(uint128 assets) internal {
        uint256 balance = IERC20Metadata(asset).balanceOf(address(this));
        liquidityRoute.provide(address(this), assets);
        uint256 received = IERC20Metadata(asset).balanceOf(address(this)) - balance;
        require(received >= assets, InsufficientLiquidity());
        SafeTransferLib.safeTransfer(asset, escrow, received);
        spoke.noteDeposit(poolId, scId, asset, 0, assets);
    }

    /// @dev `assets` less the policy's signed fee for `who`, so a rebate adds; with `grossUp`, plus it instead (the
    ///      gross whose net is `assets`). Floored at zero and capped at `uint128`, for the views.
    function _lessFee(bool isDeposit, address who, uint128 assets, bool exactOut, bool grossUp)
        internal
        view
        returns (uint128)
    {
        (int128 feeAssets,) = _quote(isDeposit, who, who, assets, exactOut);
        int256 result = grossUp ? int256(uint256(assets)) + feeAssets : int256(uint256(assets)) - feeAssets;
        if (result <= 0) return 0;
        return MathLib.min(uint256(result), type(uint128).max).toUint128();
    }

    /// @dev The policy's quote of the fee on `assets` for `who`, without recording it, with a rebate clamped to zero
    ///      so a quote never over-promises.
    function _quotedSpread(bool isDeposit, address who, uint128 assets, bool exactOut) internal view returns (uint128) {
        (int128 feeAssets,) = _quote(isDeposit, who, who, assets, exactOut);
        return feeAssets > 0 ? uint128(feeAssets) : 0;
    }

    /// @dev The instant policy's fee and recipient for a trade, the one answer both previews and trades use.
    function _quote(bool isDeposit, address sender, address receiver, uint128 assets, bool exactOut)
        internal
        view
        returns (int128 feeAssets, address recipient)
    {
        return isDeposit
            ? instantPolicy.quoteInstantDeposit(address(this), sender, receiver, assets, exactOut)
            : instantPolicy.quoteInstantRedeem(address(this), sender, receiver, assets, exactOut);
    }

    //----------------------------------------------------------------------------------------------
    // Internal: shared
    //----------------------------------------------------------------------------------------------

    function _requireLinked() internal view {
        require(_isLinked(), VaultNotLinked());
    }

    /// @dev The registered position is checked too: the registry takes any contract from a pool's factory, so another
    ///      pool could otherwise register this vault under itself and decide when it is open.
    function _isLinked() internal view returns (bool) {
        VaultDetails memory details = spokeRegistry.vaultDetails(address(this));
        return details.isLinked && details.poolId.raw() == poolId.raw() && details.scId.raw() == scId.raw()
            && details.assetId.raw() == assetId.raw();
    }

    function _readRequestPolicy(VaultConfig memory config)
        internal
        view
        returns (uint256 horizon, uint256 open, bool batches)
    {
        IRequestPolicy policy = config.plugins.requestPolicy;
        if (address(policy) == address(0)) return (config.foldHorizon, 0, false);

        open = policy.maxOpenBuckets();
        batches = policy.isBatched();
        horizon = config.foldHorizon != 0 ? config.foldHorizon : open;
        require(open != 0 && open <= horizon, InvalidFoldHorizon());
    }

    /// @dev Folds the controller's horizon into their ledger, which every claim and view starts from.
    function _foldHorizon(address controller) internal {
        _horizon.fold(_buckets, _investments[controller], controller);
    }

    /// @dev What folding the controller's horizon would add to their ledger, without folding it.
    function _unfolded(address controller) internal view returns (UnfoldedState memory) {
        return _horizon.unfolded(_buckets, _investments[controller], controller);
    }

    /// @dev What is claimable, or the instant gross net of the exit fee, which is charged on top of the payout.
    function _maxWithdraw(address owner, bool cappedAtBalance) internal view returns (uint128) {
        (bool isAsync, uint128 filled, uint128 refund, uint128 shares) = _redeemLedger(owner);
        if (isAsync) return _maxClaimWithdraw(owner, filled, refund, shares);
        if (!_isLinked()) return 0;

        (D18 ppa, D18 pps, bool valid) = _prices();
        uint128 gross = _maxInstantRedeem(owner, cappedAtBalance, ppa, pps, valid, MathLib.Rounding.Up);
        return gross == 0 ? 0 : MathLib.saturatingSub(gross, _quotedSpread(false, owner, gross, false));
    }

    function _prices() internal view returns (D18 ppa, D18 pps, bool valid) {
        return oracle.prices(poolId, scId, assetId);
    }

    /// @dev The prices, refusing to proceed unless the oracle vouches for them and neither is zero: a
    ///      zero price converts to zero, which clears every capacity check.
    function _pricesChecked() internal view returns (D18 ppa, D18 pps) {
        bool valid;
        (ppa, pps, valid) = _prices();
        require(valid && !ppa.isZero() && !pps.isZero(), InvalidPrice());
    }

    function _toShares(uint128 assets, D18 ppa, D18 pps, MathLib.Rounding rounding) internal view returns (uint128) {
        return VaultPricingLib.toShares(assets, _assetDecimals, _shareDecimals, ppa, pps, rounding);
    }

    function _toAssets(uint128 shares, D18 ppa, D18 pps, MathLib.Rounding rounding) internal view returns (uint128) {
        return VaultPricingLib.toAssets(shares, _assetDecimals, _shareDecimals, ppa, pps, rounding);
    }

    function _requireRequestManager() internal view {
        require(msg.sender == address(spokeRegistry.requestManager(poolId)), IAuth.NotAuthorized());
    }

    function _requireController(address controller) internal view {
        require(_actsFor(controller), InvalidController());
    }

    /// @dev Whether the caller acts for `controller`: the controller itself or its operator.
    function _actsFor(address controller) internal view returns (bool) {
        return controller == msg.sender || isOperator[controller][msg.sender];
    }

    function _enforceAction(VaultAction memory action) internal {
        VaultActionLib.enforce(share, action);
    }

    function _isAllowed(VaultAction memory action) internal view returns (bool) {
        return VaultActionLib.check(share, action);
    }

    /// @dev A price the oracle does not vouch for reads as unlimited, like a missing one. With no hook to ask, nobody
    ///      reads the figure, so the price is not read either.
    function _sharesEstimate(uint128 assets) internal view returns (uint128) {
        if (assets == 0 || IShareToken(share).hook() == address(0)) return 0;
        (D18 ppa, D18 pps, bool valid) = _prices();
        if (!valid) return type(uint128).max;
        return VaultPricingLib.sharesEstimate(assets, _assetDecimals, _shareDecimals, ppa, pps);
    }

    function _assetsEstimate(uint128 shares) internal view returns (uint128) {
        if (shares == 0 || IShareToken(share).hook() == address(0)) return 0;
        (D18 ppa, D18 pps, bool valid) = _prices();
        if (!valid) return type(uint128).max;
        return VaultPricingLib.assetsEstimate(shares, _assetDecimals, _shareDecimals, ppa, pps);
    }

    /// @dev A credited position closes the controller's instant lane until claimed, so crediting a controller the
    ///      caller does not act for takes a sponsor the instant policy accepts. Its consent covers its own calls and
    ///      its operators', not a spender of its allowance.
    function _requireCredit(address owner, address controller) internal view {
        if (address(instantPolicy) == address(0) || _actsFor(controller)) return;
        require(_actsFor(owner), NotSponsor());
        require(instantPolicy.canCredit(address(this), owner, controller), NotSponsor());
    }

    /// @dev Pulls `shares` from `from` and burns them; `spoke.revoke` spends the approval.
    function _revoke(address from, uint128 shares) internal {
        spoke.transferSharesFrom(poolId, scId, from, from, address(this), shares);
        SafeTransferLib.safeApprove(share, address(spoke), shares);
        spoke.revoke(poolId, scId, shares);
    }
}

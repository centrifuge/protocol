// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRegistrar} from "./interfaces/IRegistrar.sol";
import {IPoolEscrow} from "./interfaces/IPoolEscrow.sol";
import {IEndorsements} from "./interfaces/IEndorsements.sol";
import {ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";
import {IPoolEscrowProvider} from "./factories/interfaces/IPoolEscrowFactory.sol";
import {IBalanceSheet, ShareQueueAmount, AssetQueueAmount} from "./interfaces/IBalanceSheet.sol";

import {Auth} from "../../misc/Auth.sol";
import {IAuth} from "../../misc/interfaces/IAuth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {IERC6909} from "../../misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {IGateway} from "../messaging/interfaces/IGateway.sol";
import {ISpokeMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";
import {IBalanceSheetGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IManifest} from "../hub/interfaces/IManifest.sol";
import {BatchedMulticall} from "../utils/BatchedMulticall.sol";

/// @title  Balance Sheet
/// @notice Management contract that integrates all balance sheet functions of a pool:
///         - Issuing and revoking shares
///         - Depositing and withdrawing assets
///         - Reserving assets (removing them from the hub-accounted holding)
///         - Force transferring shares
///
///         Share and asset updates to the Hub are optionally queued, to reduce the cost per transaction.
///         Asset updates carry amounts only; the hub values each net delta at its own valuation, so no
///         price is read or sent on the spoke.
contract BalanceSheet is Auth, BatchedMulticall, Recoverable, IBalanceSheet, IBalanceSheetGatewayHandler {
    ISpokeRegistry public spoke;
    ISpokeMessageSender public sender;
    IEndorsements public immutable endorsements;
    IPoolEscrowProvider public poolEscrowProvider;

    mapping(PoolId => IManifest) public manifest;
    mapping(PoolId => mapping(address => bool)) public manager;
    mapping(PoolId => mapping(ShareClassId => ShareQueueAmount)) public queuedShares;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => AssetQueueAmount))) public queuedAssets;

    constructor(IEndorsements endorsements_, address deployer) Auth(deployer) BatchedMulticall(gateway) {
        endorsements = endorsements_;
    }

    /// @dev Guard for manager methods: the sender must be a manager and, if a manifest is installed, the
    ///      call must satisfy the pool's policy.
    modifier isManager(PoolId poolId) {
        _enforceManager(poolId);
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpokeRegistry(data);
        else if (what == "sender") sender = ISpokeMessageSender(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @inheritdoc IBalanceSheet
    function setManifest(PoolId poolId, IManifest manifest_) external {
        if (wards[msgSender()] != 1) _enforceManager(poolId);

        manifest[poolId] = manifest_;
        emit SetManifest(poolId, manifest_);
    }

    //----------------------------------------------------------------------------------------------
    // Asset management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable
        isManager(poolId)
    {
        escrow(poolId).deposit(scId, asset, tokenId, amount);
        _updateAssets(poolId, scId, asset, tokenId, amount, true);

        address escrow_ = address(escrow(poolId));
        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, msgSender(), escrow_, amount);
        } else {
            IERC6909(asset).transferFrom(msgSender(), escrow_, tokenId, amount);
        }
        emit Deposit(poolId, scId, msgSender(), asset, tokenId, amount);
    }

    /// @inheritdoc IBalanceSheet
    function noteDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable
        isManager(poolId)
    {
        escrow(poolId).deposit(scId, asset, tokenId, amount);
        _updateAssets(poolId, scId, asset, tokenId, amount, true);

        emit NoteDeposit(poolId, scId, msgSender(), asset, tokenId, amount);
    }

    /// @inheritdoc IBalanceSheet
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external payable isManager(poolId) {
        IPoolEscrow escrow_ = escrow(poolId);

        escrow_.withdraw(scId, asset, tokenId, receiver, amount);
        _updateAssets(poolId, scId, asset, tokenId, amount, false);
        escrow_.authTransferTo(asset, tokenId, receiver, amount);

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IBalanceSheet
    function withdrawReserved(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        address reserver,
        uint32 reason
    ) external payable isManager(poolId) {
        IPoolEscrow escrow_ = escrow(poolId);

        // Release the reservation and withdraw the freed balance: reserved and total both decrease by
        // `amount`, with no queue update since the holding decrease was already queued at reserve time.
        escrow_.unreserve(scId, asset, tokenId, amount, reserver, reason);
        escrow_.withdraw(scId, asset, tokenId, receiver, amount);
        escrow_.authTransferTo(asset, tokenId, receiver, amount);

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IBalanceSheet
    function reserve(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        uint32 reason
    ) external payable isManager(poolId) {
        escrow(poolId).reserve(scId, asset, tokenId, amount, reserver, reason);
        _updateAssets(poolId, scId, asset, tokenId, amount, false);
    }

    /// @inheritdoc IBalanceSheet
    function unreserve(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        uint32 reason
    ) external payable isManager(poolId) {
        escrow(poolId).unreserve(scId, asset, tokenId, amount, reserver, reason);
        _updateAssets(poolId, scId, asset, tokenId, amount, true);
    }

    /// @inheritdoc IBalanceSheet
    function submitQueuedAssets(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 extraGasLimit,
        address refund
    ) external payable isManager(poolId) {
        AssetQueueAmount storage assetQueue = queuedAssets[poolId][scId][assetId];
        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];

        uint32 assetCounter = (assetQueue.deposits != 0 || assetQueue.withdrawals != 0) ? 1 : 0;

        ISpokeMessageSender.UpdateData memory data = ISpokeMessageSender.UpdateData({
            netAmount: (assetQueue.deposits >= assetQueue.withdrawals)
                ? assetQueue.deposits - assetQueue.withdrawals
                : assetQueue.withdrawals - assetQueue.deposits,
            isIncrease: assetQueue.deposits > assetQueue.withdrawals,
            isSnapshot: shareQueue.delta == 0 && shareQueue.queuedAssetCounter == assetCounter,
            nonce: shareQueue.nonce
        });

        assetQueue.deposits = 0;
        assetQueue.withdrawals = 0;
        shareQueue.nonce++;
        shareQueue.queuedAssetCounter -= assetCounter;

        emit SubmitQueuedAssets(poolId, scId, assetId, data);
        sender.sendUpdateHoldingAmount{value: msgValue()}(poolId, scId, assetId, data, extraGasLimit, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Share management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external payable isManager(poolId) {
        emit Issue(poolId, scId, msgSender(), to, shares);

        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];
        (shareQueue.delta, shareQueue.isPositive) = _netShares(shareQueue.delta, shareQueue.isPositive, shares, true);

        (IERC20 token, IRegistrar registrar) = spoke.shareTokenAndRegistrar(poolId, scId);
        registrar.mint(address(token), to, shares);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external payable isManager(poolId) {
        emit Revoke(poolId, scId, msgSender(), msgSender(), shares);

        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];
        (shareQueue.delta, shareQueue.isPositive) = _netShares(shareQueue.delta, shareQueue.isPositive, shares, false);

        // Pull the shares to this contract (the caller approves this balance sheet, not the registrar),
        // then grant the registrar an allowance over this contract's balance so it can pull-and-burn.
        (IERC20 token, IRegistrar registrar) = spoke.shareTokenAndRegistrar(poolId, scId);
        SafeTransferLib.safeTransferFrom(address(token), msgSender(), address(this), shares);
        SafeTransferLib.safeApprove(address(token), address(registrar), shares);
        registrar.burn(address(token), address(this), shares);
    }

    /// @inheritdoc IBalanceSheet
    function withdrawShares(PoolId poolId, ShareClassId scId, address receiver, uint128 amount)
        external
        payable
        isManager(poolId)
    {
        // Share tokens parked in the escrow carry no holding accounting (issuance is queued via issue/revoke),
        // so this is a plain hook-checked transfer out of the escrow with no Hub queue.
        IERC20 token = spoke.shareToken(poolId, scId);
        escrow(poolId).authTransferTo(address(token), 0, receiver, amount);

        emit WithdrawShares(poolId, scId, receiver, amount);
    }

    /// @inheritdoc IBalanceSheet
    function submitQueuedShares(PoolId poolId, ShareClassId scId, uint128 extraGasLimit, address refund)
        external
        payable
        isManager(poolId)
    {
        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];

        ISpokeMessageSender.UpdateData memory data = ISpokeMessageSender.UpdateData({
            netAmount: shareQueue.delta,
            isIncrease: shareQueue.isPositive,
            isSnapshot: shareQueue.queuedAssetCounter == 0,
            nonce: shareQueue.nonce
        });

        shareQueue.delta = 0;
        shareQueue.isPositive = false;
        shareQueue.nonce++;

        emit SubmitQueuedShares(poolId, scId, data);
        sender.sendUpdateShares{value: msgValue()}(poolId, scId, data, extraGasLimit, refund);
    }

    /// @inheritdoc IBalanceSheet
    function transferSharesFrom(
        PoolId poolId,
        ShareClassId scId,
        address sender_,
        address from,
        address to,
        uint256 amount
    ) external payable isManager(poolId) {
        require(!endorsements.endorsed(from), CannotTransferFromEndorsedContract());
        (IERC20 token, IRegistrar registrar) = spoke.shareTokenAndRegistrar(poolId, scId);
        registrar.authTransferFrom(address(token), sender_, from, to, amount);
        emit TransferSharesFrom(poolId, scId, sender_, from, to, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheetGatewayHandler
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function escrow(PoolId poolId) public view returns (IPoolEscrow) {
        return poolEscrowProvider.escrow(poolId);
    }

    /// @inheritdoc IBalanceSheet
    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        public
        view
        returns (uint128)
    {
        return escrow(poolId).availableBalanceOf(scId, asset, tokenId);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev Require the sender to be a manager and, if a manifest is installed, enforce the pool's policy.
    function _enforceManager(PoolId poolId) internal {
        require(manager[poolId][msgSender()], IAuth.NotAuthorized());
        IManifest m = manifest[poolId];
        if (address(m) != address(0)) m.enforce(poolId, msgSender(), msg.data);
    }

    /// @dev Accumulate the queued gross asset flow.
    function _updateAssets(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        bool isIncrease
    ) internal {
        if (amount == 0) return;

        AssetId assetId = spoke.assetToId(asset, tokenId);
        ShareQueueAmount storage shareQueue = queuedShares[poolId][scId];
        AssetQueueAmount storage assetQueue = queuedAssets[poolId][scId][assetId];
        if (assetQueue.deposits == 0 && assetQueue.withdrawals == 0) shareQueue.queuedAssetCounter++;

        if (isIncrease) assetQueue.deposits += amount;
        else assetQueue.withdrawals += amount;
    }

    /// @dev Apply a signed share delta to the queued net (issuance adds, revocation subtracts) and return the
    ///      new magnitude and sign, computed once. The net is stored as a magnitude with a sign; a zero
    ///      magnitude is canonicalized to non-positive.
    function _netShares(uint128 delta, bool isPositive, uint128 shares, bool isIssuance)
        internal
        pure
        returns (uint128 newDelta, bool newIsPositive)
    {
        if (isIssuance == isPositive || delta == 0) {
            newDelta = delta + shares;
            newIsPositive = newDelta != 0 && isIssuance;
        } else if (delta >= shares) {
            newDelta = delta - shares;
            newIsPositive = newDelta != 0 && isPositive;
        } else {
            newDelta = shares - delta;
            newIsPositive = isIssuance;
        }
    }
}

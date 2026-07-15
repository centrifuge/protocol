// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFeeHook} from "./interfaces/IFeeHook.sol";
import {IHoldings} from "./interfaces/IHoldings.sol";
import {IManifest} from "./interfaces/IManifest.sol";
import {IValuation} from "./interfaces/IValuation.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IBridgingHook} from "./interfaces/IBridgingHook.sol";
import {ISnapshotHook} from "./interfaces/ISnapshotHook.sol";
import {IAccounting, JournalEntry} from "./interfaces/IAccounting.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";
import {IShareClassManager} from "./interfaces/IShareClassManager.sol";
import {IHub, VaultUpdateKind, ManagerKind, AccountKind} from "./interfaces/IHub.sol";
import {IHubRequestManagerCallback} from "./interfaces/IHubRequestManagerCallback.sol";

import {Auth} from "../../misc/Auth.sol";
import {d18, D18} from "../../misc/types/D18.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

import {IAdapter} from "../messaging/interfaces/IAdapter.sol";
import {IGateway} from "../messaging/interfaces/IGateway.sol";
import {IMultiAdapter} from "../messaging/interfaces/IMultiAdapter.sol";
import {IHubMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";

import {ICreatePool} from "../../admin/interfaces/ICreatePool.sol";

import {RequestCallbackMessageLib} from "../../vaults/libraries/RequestCallbackMessageLib.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {AccountId} from "../types/AccountId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {BatchedMulticall} from "../utils/BatchedMulticall.sol";

/// @title  Hub
/// @notice Central pool management contract, that brings together all functions in one place.
///         Pools can assign hub managers which have full rights over all actions.
contract Hub is BatchedMulticall, Auth, Recoverable, IHub, IHubRequestManagerCallback, ICreatePool {
    using MathLib for uint256;
    using CastLib for bytes32;
    using RequestCallbackMessageLib for *;

    IFeeHook public feeHook;
    IHoldings public holdings;
    IAccounting public accounting;
    IHubRegistry public hubRegistry;
    IHubMessageSender public sender;
    IMultiAdapter public multiAdapter;
    IShareClassManager public shareClassManager;

    constructor(
        IGateway gateway_,
        IHoldings holdings_,
        IAccounting accounting_,
        IHubRegistry hubRegistry_,
        IMultiAdapter multiAdapter_,
        IShareClassManager shareClassManager_,
        address deployer
    ) Auth(deployer) BatchedMulticall(gateway_) {
        holdings = holdings_;
        accounting = accounting_;
        hubRegistry = hubRegistry_;
        multiAdapter = multiAdapter_;
        shareClassManager = shareClassManager_;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function file(bytes32 what, address data) external {
        _auth();

        if (what == "gateway") gateway = IGateway(data);
        else if (what == "feeHook") feeHook = IFeeHook(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "shareClassManager") shareClassManager = IShareClassManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ICreatePool
    function createPool(PoolId poolId, address admin, AssetId currency) external payable {
        _auth();

        require(poolId.centrifugeId() == sender.localCentrifugeId(), InvalidPoolId());
        hubRegistry.registerPool(poolId, admin, currency);
    }

    /// @inheritdoc IHub
    function setManifest(PoolId poolId, IManifest manifest_) external {
        // Wards may install/replace directly (emergency override); managers go through the current
        // manifest's policy (via _protected), so a compromised manager can't hot-swap it in one tx.
        if (wards[msgSender()] != 1) _protected(poolId);

        hubRegistry.setManifest(poolId, manifest_);
    }

    /// @inheritdoc IHub
    function manifest(PoolId poolId) external view returns (IManifest) {
        return hubRegistry.manifest(poolId);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Authorization ledger
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function authorize(PoolId poolId, bytes calldata data) external {
        _requireManager(poolId);

        hubRegistry.authorize(poolId, msgSender(), data);
    }

    /// @inheritdoc IHub
    function cancelAuthorization(PoolId poolId, bytes calldata data) external {
        _requireManager(poolId);

        hubRegistry.cancelAuthorization(poolId, msgSender(), data);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Pool configuration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function setAdapters(
        PoolId poolId,
        uint16 centrifugeId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        address refund
    ) external payable {
        _protected(poolId);

        // Batching would defer the send until after the new set is applied, routing over a set the
        // destination lacks, so it is disallowed here.
        require(!gateway.isBatching(), CannotSetAdaptersWhileBatching());

        // Send the remote update before applying the local set: SetPoolAdapters routes over the pool's
        // own set, so it must travel over the set still shared with the destination.
        sender.sendSetPoolAdapters{value: msgValue()}(centrifugeId, poolId, remoteAdapters, threshold, refund);

        multiAdapter.setAdapters(centrifugeId, poolId, localAdapters, threshold);
    }

    /// @inheritdoc IHub
    function setBridgingHook(PoolId poolId, address hook) external {
        _protected(poolId);

        hubRegistry.setBridgingHook(poolId, IBridgingHook(hook));
        emit SetBridgingHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable {
        _protected(poolId);

        holdings.setSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable {
        _protected(poolId);

        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function updateCurrency(PoolId poolId, AssetId currency) external {
        _protected(poolId);

        hubRegistry.updateCurrency(poolId, currency);
    }

    /// @inheritdoc IHub
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable
    {
        _protected(poolId);

        shareClassManager.updateMetadata(poolId, scId, name, symbol);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Permissions & routing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable {
        _protected(poolId);

        hubRegistry.updateManager(poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function updateManager(
        PoolId poolId,
        uint16 centrifugeId,
        ManagerKind kind,
        bytes32 who,
        bool canManage,
        address refund
    ) external payable {
        _protected(poolId);

        emit UpdateManager(centrifugeId, poolId, kind, who, canManage);
        sender.sendUpdateManager{value: msgValue()}(centrifugeId, poolId, kind, who, canManage, refund);
    }

    /// @inheritdoc IHub
    function setRequestManager(
        PoolId poolId,
        uint16 centrifugeId,
        IHubRequestManager hubManager,
        bytes32 spokeManager,
        address refund
    ) external payable {
        _protected(poolId);

        hubRegistry.setHubRequestManager(poolId, centrifugeId, hubManager);

        emit SetSpokeRequestManager(centrifugeId, poolId, spokeManager);
        sender.sendSetRequestManager{value: msgValue()}(centrifugeId, poolId, spokeManager, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Share classes & vaults
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId)
    {
        _protected(poolId);

        return shareClassManager.addShareClass(poolId, name, symbol, salt);
    }

    /// @inheritdoc IHub
    function updateRestriction(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable {
        _protected(poolId);

        _requireSC(poolId, scId);

        emit UpdateRestriction(centrifugeId, poolId, scId, payload);
        sender.sendUpdateRestriction{value: msgValue()}(centrifugeId, poolId, scId, payload, extraGasLimit, refund);
    }

    /// @inheritdoc IHub
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        uint128 extraGasLimit,
        address refund
    ) external payable {
        _protected(poolId);

        _requireSC(poolId, scId);

        emit UpdateVault(poolId, scId, assetId, vaultOrFactory, kind);
        sender.sendUpdateVault{value: msgValue()}(poolId, scId, assetId, vaultOrFactory, kind, extraGasLimit, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Holdings & accounting
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt)
        external
        payable
    {
        _protected(poolId);

        shareClassManager.updateSharePrice(poolId, scId, pricePoolPerShare, computedAt);

        _accrue(poolId, scId);
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external payable {
        _protected(poolId);

        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable {
        _protected(poolId);

        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IHub
    function initializeHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId[4] calldata accounts
    ) external payable {
        _protected(poolId);

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        for (uint256 i; i < accounts.length; i++) {
            require(accounting.exists(poolId, accounts[i]), IAccounting.AccountDoesNotExist());
        }

        holdings.initialize(poolId, scId, assetId, valuation, accounts);

        // If increase/decrease was called before initialize, we add journal entries for this
        _updateAccountingAmount(poolId, scId, assetId, true, holdings.value(poolId, scId, assetId));
    }

    /// @inheritdoc IHub
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable {
        _protected(poolId);

        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);
        _updateAccountingValue(poolId, scId, assetId, isPositive, diff);

        holdings.callOnSyncSnapshot(poolId, scId, assetId.centrifugeId());
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable
    {
        _protected(poolId);

        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IHub
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable
    {
        _protected(poolId);

        require(accounting.exists(poolId, accountId), IAccounting.AccountDoesNotExist());

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits)
        external
        payable
    {
        _protected(poolId);

        accounting.unlock(poolId);
        accounting.addJournal(debits, credits);
        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Spoke notifications
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable {
        _protected(poolId);

        emit NotifyPool(centrifugeId, poolId);
        sender.sendNotifyPool{value: msgValue()}(centrifugeId, poolId, refund);
    }

    /// @inheritdoc IHub
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable
    {
        _protected(poolId);

        _requireSC(poolId, scId);

        (string memory name, string memory symbol, bytes32 salt) = shareClassManager.metadata(poolId, scId);
        uint8 decimals = hubRegistry.decimals(poolId);

        emit NotifyShareClass(centrifugeId, poolId, scId);
        sender.sendNotifyShareClass{value: msgValue()}(
            centrifugeId, poolId, scId, name, symbol, decimals, salt, hook, refund
        );
    }

    /// @inheritdoc IHub
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund)
        external
        payable
    {
        _protected(poolId);

        (string memory name, string memory symbol,) = shareClassManager.metadata(poolId, scId);

        emit NotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
        sender.sendNotifyShareMetadata{value: msgValue()}(centrifugeId, poolId, scId, name, symbol, refund);
    }

    /// @inheritdoc IHub
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable
    {
        _protected(poolId);

        emit UpdateShareHook(centrifugeId, poolId, scId, hook);
        sender.sendUpdateShareHook{value: msgValue()}(centrifugeId, poolId, scId, hook, refund);
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) external payable {
        _protected(poolId);

        (D18 pricePoolPerShare, uint64 computedAt) = shareClassManager.pricePoolPerShare(poolId, scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, pricePoolPerShare, computedAt);
        sender.sendNotifyPricePoolPerShare{value: msgValue()}(
            centrifugeId, poolId, scId, pricePoolPerShare, computedAt, refund
        );
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId, address refund) external payable {
        _protected(poolId);

        D18 pricePoolPerAsset_ = pricePoolPerAsset(poolId, scId, assetId);
        emit NotifyAssetPrice(assetId.centrifugeId(), poolId, scId, assetId, pricePoolPerAsset_);
        sender.sendNotifyPricePoolPerAsset{value: msgValue()}(poolId, scId, assetId, pricePoolPerAsset_, refund);

        _accrue(poolId, scId);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Envoy calls
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function managerCall(
        PoolId poolId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        uint256 localValue,
        address refund
    ) external payable {
        _protected(poolId);

        // Gas is explicit: a local call is funded entirely by `msg.value`, a remote call carries none.
        require(
            centrifugeId == sender.localCentrifugeId() ? localValue == msgValue() : localValue == 0,
            ManagerCallUnexpectedValue()
        );

        emit ManagerCall(centrifugeId, poolId, target, payload);
        sender.sendManagerHubCall{value: msgValue()}(
            centrifugeId, poolId, target.toAddress(), payload, extraGasLimit, localValue, refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // Request manager callback
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRequestManagerCallback
    function requestCallback(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit,
        bool unpaidMode,
        address refund
    ) external payable {
        IHubRequestManager manager = hubRegistry.hubRequestManager(poolId, assetId.centrifugeId());
        require(address(manager) != address(0), InvalidRequestManager());
        require(msg.sender == address(manager), NotAuthorized());

        sender.sendRequestCallback{value: msgValue()}(poolId, scId, assetId, payload, extraGasLimit, unpaidMode, refund);
    }

    //----------------------------------------------------------------------------------------------
    //  Accounting methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    /// @notice Create credit & debit entries for the deposit or withdrawal of a holding.
    ///         This posts against the AmountDebit and AmountCredit account slots.
    function updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        payable
        auth
    {
        _updateAccountingAmount(poolId, scId, assetId, isPositive, diff);
    }

    function _updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        internal
    {
        if (diff == 0) return;
        if (isPositive) _journal(poolId, scId, assetId, diff, AccountKind.AmountDebit, AccountKind.AmountCredit);
        else _journal(poolId, scId, assetId, diff, AccountKind.AmountCredit, AccountKind.AmountDebit);
    }

    /// @inheritdoc IHub
    /// @notice Create credit & debit entries for the increase or decrease in the value of a holding.
    ///         This posts against the AmountDebit slot and the ValueIncrease/ValueDecrease account slots.
    function updateAccountingValue(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        payable
        auth
    {
        _updateAccountingValue(poolId, scId, assetId, isPositive, diff);
    }

    function _updateAccountingValue(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        internal
    {
        if (diff == 0) return;
        if (isPositive) _journal(poolId, scId, assetId, diff, AccountKind.AmountDebit, AccountKind.ValueIncrease);
        else _journal(poolId, scId, assetId, diff, AccountKind.ValueDecrease, AccountKind.AmountDebit);
    }

    /// @dev Unlock, post the debit/credit pair against the given account slots, then lock.
    function _journal(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 diff,
        AccountKind debitKind,
        AccountKind creditKind
    ) private {
        accounting.unlock(poolId);
        accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(debitKind)), diff);
        accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(creditKind)), diff);
        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    //  View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (D18) {
        // Assume price of 1.0 if the holding is not initialized yet
        if (!holdings.isInitialized(poolId, scId, assetId)) return d18(1, 1);

        IValuation valuation = holdings.valuation(poolId, scId, assetId);
        return valuation.getPrice(poolId, scId, assetId);
    }

    //----------------------------------------------------------------------------------------------
    //  Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Ensure the sender is authorized
    function _auth() internal auth {}

    /// @dev Guard for manager methods: the sender must be a pool manager and the call must
    ///      satisfy the pool's policy. When a guard is installed it classifies the current call
    ///      against the pool's manifest, running synchronously when in policy, or consuming a
    ///      matured authorization when out of policy (reverting otherwise).
    function _protected(PoolId poolId) internal {
        _requireManager(poolId);

        IManifest m = hubRegistry.manifest(poolId);
        if (address(m) != address(0)) m.enforce(poolId, msgSender(), msg.data);
    }

    /// @dev Reverts unless the resolved sender is a registered manager for `poolId`.
    function _requireManager(PoolId poolId) internal view {
        require(hubRegistry.manager(poolId, msgSender()), IHub.NotManager());
    }

    /// @dev Ensure the share class exists for the pool.
    function _requireSC(PoolId poolId, ShareClassId scId) private view {
        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());
    }

    /// @dev Accrue protocol fees for the share class if a fee hook is configured.
    function _accrue(PoolId poolId, ShareClassId scId) private {
        if (address(feeHook) != address(0)) feeHook.accrue(poolId, scId);
    }
}

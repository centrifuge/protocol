// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHoldings} from "./interfaces/IHoldings.sol";
import {IValuation} from "./interfaces/IValuation.sol";
import {IFeeAccrual} from "./interfaces/IFeeAccrual.sol";
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
import {IHubMessageSender, ShareClassMetadata} from "../messaging/interfaces/IGatewaySenders.sol";

import {ICreatePool} from "../../admin/interfaces/ICreatePool.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {AccountId} from "../types/AccountId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IHubPolicy} from "../utils/interfaces/IPolicy.sol";
import {BatchedMulticall} from "../utils/BatchedMulticall.sol";

/// @title  Hub
/// @notice Central pool management contract, that brings together all functions in one place.
///         Pools can assign hub managers which have full rights over all actions.
contract Hub is BatchedMulticall, Auth, Recoverable, IHub, IHubRequestManagerCallback, ICreatePool {
    using MathLib for uint256;
    using CastLib for bytes32;

    IFeeAccrual public feeAccrual;
    IHubMessageSender public sender;
    IMultiAdapter public multiAdapter;

    IHoldings public immutable holdings;
    IAccounting public immutable accounting;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

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

    /// @dev Manager-only, and enforces the pool's policy if one is installed.
    modifier enforced(PoolId poolId) {
        _enforce(poolId);
        _;
    }

    /// @dev Sender must be a registered manager for the pool (no policy applied).
    modifier onlyManager(PoolId poolId) {
        _requireManager(poolId);
        _;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "feeAccrual") feeAccrual = IFeeAccrual(data);
        else if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ICreatePool
    function createPool(PoolId poolId, address admin, AssetId currency) external payable auth {
        require(poolId.centrifugeId() == sender.localCentrifugeId(), InvalidPoolId());
        hubRegistry.registerPool(poolId, admin, currency);
    }

    /// @inheritdoc IHub
    function setPolicy(PoolId poolId, IHubPolicy policy_) external {
        if (wards[msgSender()] != 1) _enforce(poolId);

        hubRegistry.setPolicy(poolId, policy_);
    }

    /// @inheritdoc IHub
    function policy(PoolId poolId) external view returns (IHubPolicy) {
        return hubRegistry.policy(poolId);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Authorization ledger
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function initiateAuthorization(PoolId poolId, bytes calldata data) external onlyManager(poolId) {
        hubRegistry.initiateAuthorization(poolId, msgSender(), data);
    }

    /// @inheritdoc IHub
    function cancelAuthorization(PoolId poolId, bytes calldata data) external enforced(poolId) {
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
    ) external payable enforced(poolId) {
        // Batching would defer the send until after the new set is applied, routing over a set the
        // destination lacks, so it is disallowed here.
        require(!gateway.isBatching(), CannotSetAdaptersWhileBatching());

        // Send the remote update before applying the local set: SetPoolAdapters routes over the pool's
        // own set, so it must travel over the set still shared with the destination.
        uint16 targetSessionId = multiAdapter.nextActiveSessionId(centrifugeId, poolId);
        sender.sendSetPoolAdapters{value: msgValue()}(
            centrifugeId, poolId, remoteAdapters, threshold, targetSessionId, refund
        );

        multiAdapter.setAdapters(centrifugeId, poolId, localAdapters, threshold, targetSessionId);
    }

    /// @inheritdoc IHub
    function setBridgingHook(PoolId poolId, address hook) external enforced(poolId) {
        hubRegistry.setBridgingHook(poolId, IBridgingHook(hook));
    }

    /// @inheritdoc IHub
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable enforced(poolId) {
        holdings.setSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable enforced(poolId) {
        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function updateCurrency(PoolId poolId, AssetId currency) external enforced(poolId) {
        hubRegistry.updateCurrency(poolId, currency);
    }

    /// @inheritdoc IHub
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable
        enforced(poolId)
    {
        shareClassManager.updateMetadata(poolId, scId, name, symbol);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Permissions & routing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable enforced(poolId) {
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
    ) external payable enforced(poolId) {
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
    ) external payable enforced(poolId) {
        hubRegistry.setHubRequestManager(poolId, centrifugeId, hubManager);

        emit SetSpokeRequestManager(centrifugeId, poolId, spokeManager);
        sender.sendSetRequestManager{value: msgValue()}(centrifugeId, poolId, spokeManager, refund);
    }

    /// @inheritdoc IHub
    function setSpokePolicy(PoolId poolId, uint16 centrifugeId, bytes32 policy_, address refund) external payable {
        _enforce(poolId);

        emit SetSpokePolicy(centrifugeId, poolId, policy_);
        sender.sendSetPolicy{value: msgValue()}(centrifugeId, poolId, policy_, refund);
    }

    /// @inheritdoc IHub
    function authorizeSpokeCall(PoolId poolId, uint16 centrifugeId, bytes calldata data, address refund)
        external
        payable
    {
        _enforce(poolId);

        emit AuthorizeSpokeCall(centrifugeId, poolId, data);
        sender.sendAuthorizeSpokeCall{value: msgValue()}(centrifugeId, poolId, data, refund);
    }

    /// @inheritdoc IHub
    function unauthorizeSpokeCall(PoolId poolId, uint16 centrifugeId, bytes calldata data, address refund)
        external
        payable
    {
        // Manager-only and immediate (no timelock): revoking an authorization only reduces capability, so it
        // is a safety action a manager can take at any time to retire a stale, not-yet-consumed authorization.
        _requireManager(poolId);

        emit UnauthorizeSpokeCall(centrifugeId, poolId, data);
        sender.sendUnauthorizeSpokeCall{value: msgValue()}(centrifugeId, poolId, data, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Share classes & vaults
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        enforced(poolId)
        returns (ShareClassId scId)
    {
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
    ) external payable enforced(poolId) {
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
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable enforced(poolId) {
        _requireSC(poolId, scId);

        emit UpdateVault(poolId, scId, assetId, vaultOrFactory, kind, payload);
        sender.sendUpdateVault{value: msgValue()}(
            poolId, scId, assetId, vaultOrFactory, kind, payload, extraGasLimit, refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Holdings & accounting
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt)
        public
        payable
        enforced(poolId)
    {
        shareClassManager.updateSharePrice(poolId, scId, pricePoolPerShare, computedAt);
        _accrue(poolId, scId);
    }

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) external payable {
        updateSharePrice(poolId, scId, pricePoolPerShare, uint64(block.timestamp));
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external payable enforced(poolId) {
        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata)
        external
        payable
        enforced(poolId)
    {
        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IHub
    function initializeHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId[4] calldata accounts
    ) external payable enforced(poolId) {
        _requireSC(poolId, scId);

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        for (uint256 i; i < accounts.length; i++) {
            require(accounting.exists(poolId, accounts[i]), IAccounting.AccountDoesNotExist());
        }

        holdings.initialize(poolId, scId, assetId, valuation, accounts);

        // If increase/decrease was called before initialize, the tracked amount carries no value yet:
        // establish it at the valuation and book it as principal.
        (, uint128 initialValue) = holdings.update(poolId, scId, assetId);
        _updateAccountingAmount(poolId, scId, assetId, true, initialValue);
    }

    /// @inheritdoc IHub
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable enforced(poolId) {
        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);
        _updateAccountingValue(poolId, scId, assetId, isPositive, diff);

        holdings.callOnSyncSnapshot(poolId, scId, assetId.centrifugeId());
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable
        enforced(poolId)
    {
        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IHub
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable
        enforced(poolId)
    {
        require(accounting.exists(poolId, accountId), IAccounting.AccountDoesNotExist());

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits)
        external
        payable
        enforced(poolId)
    {
        accounting.unlock(poolId);
        accounting.addJournal(debits, credits);
        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    // Manager: Spoke notifications
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable enforced(poolId) {
        emit NotifyPool(centrifugeId, poolId);
        sender.sendNotifyPool{value: msgValue()}(centrifugeId, poolId, refund);
    }

    /// @inheritdoc IHub
    function notifyShareClass(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 registrar,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable {
        _enforce(poolId);
        _requireSC(poolId, scId);

        (ShareClassMetadata memory metadata, bytes32 salt) = _shareClassMetadata(poolId, scId);

        emit NotifyShareClass(centrifugeId, poolId, scId, payload);
        sender.sendNotifyShareClass{value: msgValue()}(
            centrifugeId, poolId, scId, metadata, salt, registrar, payload, extraGasLimit, refund
        );
    }

    /// @dev Reads a share class's creation metadata into a struct, keeping the name/symbol locals out of the
    ///      caller's stack frame (avoids stack-too-deep in {notifyShareClass}).
    function _shareClassMetadata(PoolId poolId, ShareClassId scId)
        internal
        view
        returns (ShareClassMetadata memory metadata, bytes32 salt)
    {
        string memory name;
        string memory symbol;
        (name, symbol, salt) = shareClassManager.metadata(poolId, scId);
        metadata = ShareClassMetadata(name, symbol, hubRegistry.decimals(poolId));
    }

    /// @inheritdoc IHub
    function notifyShareMetadata(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        uint128 extraGasLimit,
        address refund
    ) external payable enforced(poolId) {
        (string memory name, string memory symbol,) = shareClassManager.metadata(poolId, scId);

        emit NotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
        sender.sendNotifyShareMetadata{value: msgValue()}(
            centrifugeId, poolId, scId, name, symbol, extraGasLimit, refund
        );
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund)
        external
        payable
        enforced(poolId)
    {
        (D18 pricePoolPerShare, uint64 computedAt) = shareClassManager.pricePoolPerShare(poolId, scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, pricePoolPerShare, computedAt);
        sender.sendNotifyPricePoolPerShare{value: msgValue()}(
            centrifugeId, poolId, scId, pricePoolPerShare, computedAt, refund
        );
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId, address refund)
        external
        payable
        enforced(poolId)
    {
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
    ) external payable enforced(poolId) {
        // Gas is explicit: a local call is funded entirely by `msg.value`, a remote call carries none.
        require(
            centrifugeId == sender.localCentrifugeId() ? localValue == msgValue() : localValue == 0,
            ManagerCallUnexpectedValue()
        );

        emit ManagerCall(centrifugeId, poolId, target, payload);
        sender.sendManagerCallFromHub{value: msgValue()}(
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

    function _enforce(PoolId poolId) internal {
        _requireManager(poolId);

        IHubPolicy policy_ = hubRegistry.policy(poolId);
        if (address(policy_) != address(0)) policy_.enforce(poolId, msgSender(), msg.data);
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
        if (address(feeAccrual) != address(0)) feeAccrual.accrue(poolId, scId);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFeeHook} from "./interfaces/IFeeHook.sol";
import {IValuation} from "./interfaces/IValuation.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {ISnapshotHook} from "./interfaces/ISnapshotHook.sol";
import {IHoldings, HoldingAccount} from "./interfaces/IHoldings.sol";
import {IAccounting, JournalEntry} from "./interfaces/IAccounting.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";
import {IShareClassManager} from "./interfaces/IShareClassManager.sol";
import {IHub, VaultUpdateKind, AccountType, PendingOp} from "./interfaces/IHub.sol";
import {IHubRequestManagerCallback} from "./interfaces/IHubRequestManagerCallback.sol";
import {IManifest} from "../../managers/hub/interfaces/ISupervisor.sol";

import {Auth} from "../../misc/Auth.sol";
import {d18, D18} from "../../misc/types/D18.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
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
///         Per-pool manifests enforce policy on all manager calls, optionally deferring
///         operations via timelocks.
contract Hub is BatchedMulticall, Auth, Recoverable, IHub, IHubRequestManagerCallback, ICreatePool {
    using MathLib for uint256;
    using RequestCallbackMessageLib for *;

    IFeeHook public feeHook;
    IHoldings public holdings;
    IAccounting public accounting;
    IHubRegistry public hubRegistry;
    IHubMessageSender public sender;
    IMultiAdapter public multiAdapter;
    IShareClassManager public shareClassManager;

    address private transient _submitter;
    mapping(PoolId => IManifest) public manifest;
    mapping(bytes32 => PendingOp) public pending;

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

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable {
        if (!_guard(poolId)) return;

        emit NotifyPool(centrifugeId, poolId);
        sender.sendNotifyPool{value: msgValue()}(centrifugeId, poolId, refund);
    }

    /// @inheritdoc IHub
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable
    {
        if (!_guard(poolId)) return;

        _requireSC(poolId, scId);

        (string memory name, string memory symbol, bytes32 salt) = shareClassManager.metadata(poolId, scId);
        uint8 decimals = hubRegistry.decimals(poolId);

        emit NotifyShareClass(centrifugeId, poolId, scId);
        sender.sendNotifyShareClass{value: msgValue()}(
            centrifugeId, poolId, scId, name, symbol, decimals, salt, hook, refund
        );
    }

    /// @inheritdoc IHub
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) public payable {
        if (!_guard(poolId)) return;

        (string memory name, string memory symbol,) = shareClassManager.metadata(poolId, scId);

        emit NotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
        sender.sendNotifyShareMetadata{value: msgValue()}(centrifugeId, poolId, scId, name, symbol, refund);
    }

    /// @inheritdoc IHub
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        public
        payable
    {
        if (!_guard(poolId)) return;

        emit UpdateShareHook(centrifugeId, poolId, scId, hook);
        sender.sendUpdateShareHook{value: msgValue()}(centrifugeId, poolId, scId, hook, refund);
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) public payable {
        if (!_guard(poolId)) return;

        (D18 pricePoolPerShare, uint64 computedAt) = shareClassManager.pricePoolPerShare(poolId, scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, pricePoolPerShare, computedAt);
        sender.sendNotifyPricePoolPerShare{value: msgValue()}(
            centrifugeId, poolId, scId, pricePoolPerShare, computedAt, refund
        );
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId, address refund) public payable {
        if (!_guard(poolId)) return;

        D18 pricePoolPerAsset_ = pricePoolPerAsset(poolId, scId, assetId);
        emit NotifyAssetPrice(assetId.centrifugeId(), poolId, scId, assetId, pricePoolPerAsset_);
        sender.sendNotifyPricePoolPerAsset{value: msgValue()}(poolId, scId, assetId, pricePoolPerAsset_, refund);

        _accrue(poolId, scId);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable {
        if (!_guard(poolId)) return;

        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable {
        if (!_guard(poolId)) return;

        holdings.setSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable
    {
        if (!_guard(poolId)) return;

        shareClassManager.updateMetadata(poolId, scId, name, symbol);
    }

    /// @inheritdoc IHub
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable {
        if (!_guard(poolId)) return;

        hubRegistry.updateManager(poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function setRequestManager(
        PoolId poolId,
        uint16 centrifugeId,
        IHubRequestManager hubManager,
        bytes32 spokeManager,
        address refund
    ) external payable {
        if (!_guard(poolId)) return;

        hubRegistry.setHubRequestManager(poolId, centrifugeId, hubManager);

        emit SetSpokeRequestManager(centrifugeId, poolId, spokeManager);
        sender.sendSetRequestManager{value: msgValue()}(centrifugeId, poolId, spokeManager, refund);
    }

    /// @inheritdoc IHub
    function updateBalanceSheetManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable
    {
        if (!_guard(poolId)) return;

        emit UpdateBalanceSheetManager(centrifugeId, poolId, who, canManage);
        sender.sendUpdateBalanceSheetManager{value: msgValue()}(centrifugeId, poolId, who, canManage, refund);
    }

    /// @inheritdoc IHub
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId)
    {
        if (!_guard(poolId)) return scId;

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
        if (!_guard(poolId)) return;

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
        if (!_guard(poolId)) return;

        _requireSC(poolId, scId);

        emit UpdateVault(poolId, scId, assetId, vaultOrFactory, kind);
        sender.sendUpdateVault{value: msgValue()}(poolId, scId, assetId, vaultOrFactory, kind, extraGasLimit, refund);
    }

    /// @inheritdoc IHub
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable {
        if (!_guard(poolId)) return;

        _requireSC(poolId, scId);

        emit UpdateContract(centrifugeId, poolId, scId, target, payload);
        sender.sendTrustedContractUpdate{value: msgValue()}(
            centrifugeId, poolId, scId, target, payload, extraGasLimit, refund
        );
    }

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt)
        public
        payable
    {
        if (!_guard(poolId)) return;

        shareClassManager.updateSharePrice(poolId, scId, pricePoolPerShare, computedAt);

        _accrue(poolId, scId);
    }

    /// @inheritdoc IHub
    function initializeHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) external payable {
        if (!_guard(poolId)) return;

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        require(
            assetAccount != equityAccount && assetAccount != gainAccount && assetAccount != lossAccount,
            IHub.InvalidAccountCombination()
        );
        require(
            accounting.exists(poolId, assetAccount) && accounting.exists(poolId, equityAccount)
                && accounting.exists(poolId, lossAccount) && accounting.exists(poolId, gainAccount),
            IAccounting.AccountDoesNotExist()
        );

        holdings.initialize(
            poolId,
            scId,
            assetId,
            valuation,
            false,
            holdingAccounts(assetAccount, equityAccount, gainAccount, lossAccount)
        );

        // If increase/decrease was called before initialize, we add journal entries for this
        _updateAccountingAmount(poolId, scId, assetId, true, holdings.value(poolId, scId, assetId));
    }

    /// @inheritdoc IHub
    function initializeLiability(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId expenseAccount,
        AccountId liabilityAccount
    ) external payable {
        if (!_guard(poolId)) return;

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        require(expenseAccount != liabilityAccount, IHub.InvalidAccountCombination());
        require(
            accounting.exists(poolId, expenseAccount) && accounting.exists(poolId, liabilityAccount),
            IAccounting.AccountDoesNotExist()
        );

        holdings.initialize(poolId, scId, assetId, valuation, true, liabilityAccounts(expenseAccount, liabilityAccount));

        // If increase/decrease was called before initialize, we add journal entries for this
        _updateAccountingAmount(poolId, scId, assetId, true, holdings.value(poolId, scId, assetId));
    }

    /// @inheritdoc IHub
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) public payable {
        if (!_guard(poolId)) return;

        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);
        _updateAccountingValue(poolId, scId, assetId, isPositive, diff);

        holdings.callOnSyncSnapshot(poolId, scId, assetId.centrifugeId());
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable
    {
        if (!_guard(poolId)) return;

        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IHub
    function updateHoldingIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability)
        external
        payable
    {
        if (!_guard(poolId)) return;

        holdings.updateIsLiability(poolId, scId, assetId, isLiability);
    }

    /// @inheritdoc IHub
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable
    {
        if (!_guard(poolId)) return;

        require(accounting.exists(poolId, accountId), IAccounting.AccountDoesNotExist());

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) public payable {
        if (!_guard(poolId)) return;

        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable {
        if (!_guard(poolId)) return;

        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IHub
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits)
        external
        payable
    {
        if (!_guard(poolId)) return;

        accounting.unlock(poolId);
        accounting.addJournal(debits, credits);
        accounting.lock();
    }

    /// @inheritdoc IHub
    function setAdapters(
        PoolId poolId,
        uint16 centrifugeId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        uint8 recoveryIndex,
        address refund
    ) external payable {
        if (!_guard(poolId)) return;

        multiAdapter.setAdapters(centrifugeId, poolId, localAdapters, threshold, recoveryIndex);

        sender.sendSetPoolAdapters{value: msgValue()}(
            centrifugeId, poolId, remoteAdapters, threshold, recoveryIndex, refund
        );
    }

    /// @inheritdoc IHub
    function updateGatewayManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable
    {
        if (!_guard(poolId)) return;

        sender.sendUpdateGatewayManager{value: msgValue()}(centrifugeId, poolId, who, canManage, refund);
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
    ///         This updates the asset/expense as well as the equity/liability accounts.
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
        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType a = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType b = isLiability ? AccountType.Liability : AccountType.Equity;
        _journal(poolId, scId, assetId, isPositive, diff, a, b);
    }

    /// @inheritdoc IHub
    /// @notice Create credit & debit entries for the increase or decrease in the value of a holding.
    ///         This updates the asset/expense as well as the gain/loss accounts.
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
        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType a = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType b = isLiability ? AccountType.Liability : (isPositive ? AccountType.Gain : AccountType.Loss);
        _journal(poolId, scId, assetId, isPositive, diff, a, b);
    }

    function _journal(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bool isPositive,
        uint128 diff,
        AccountType debitType,
        AccountType creditType
    ) private {
        accounting.unlock(poolId);
        AccountId debitAcct = holdings.accountId(poolId, scId, assetId, uint8(debitType));
        AccountId creditAcct = holdings.accountId(poolId, scId, assetId, uint8(creditType));
        if (isPositive) {
            accounting.addDebit(debitAcct, diff);
            accounting.addCredit(creditAcct, diff);
        } else {
            accounting.addDebit(creditAcct, diff);
            accounting.addCredit(debitAcct, diff);
        }
        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    // Manifest & timelock methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function setManifest(PoolId poolId, IManifest manifest_) external {
        require(hubRegistry.manager(poolId, msgSender()), NotManager());
        manifest[poolId] = manifest_;
    }

    /// @inheritdoc IHub
    function execute(bytes calldata data) external payable {
        require(_submitter == address(0), PoolAlreadyUnlocked());
        _checkManager(data);

        bytes32 opId = keccak256(data);
        PendingOp memory op = pending[opId];
        require(op.executeAfter != 0, OperationNotPending());
        require(block.timestamp >= op.executeAfter, TimelockNotReady(op.executeAfter));
        delete pending[opId];

        // Replay original call with original sender context
        _submitter = op.submitter;
        (bool success, bytes memory result) = address(this).call(data);
        _submitter = address(0);
        if (!success) revert ExecutionFailed(result);

        emit OperationExecuted(opId);
    }

    /// @inheritdoc IHub
    function cancel(bytes calldata data) external {
        _checkManager(data);

        bytes32 opId = keccak256(data);
        require(pending[opId].executeAfter != 0, OperationNotPending());
        delete pending[opId];

        emit OperationCanceled(opId);
    }

    /// @dev Ensure the sender is a pool manager. When a manifest is set and returns a timelock > 0,
    ///      the operation is stored as pending and the caller should return early.
    function _guard(PoolId poolId) private returns (bool) {
        require(hubRegistry.manager(poolId, msgSender()), NotManager());
        if (_submitter != address(0)) return true; // Replaying via execute — skip manifest

        IManifest m = manifest[poolId];
        if (address(m) == address(0)) return true; // No manifest — immediate execution

        uint48 timelock = m.check(poolId, msgSender(), msg.data);
        if (timelock == 0) return true; // Manifest approved — immediate execution

        // Auto-submit as pending
        bytes32 opId = keccak256(msg.data);
        require(pending[opId].executeAfter == 0, OperationAlreadyPending());
        uint48 executeAfter = uint48(block.timestamp) + timelock;
        pending[opId] = PendingOp(executeAfter, msgSender());
        emit OperationSubmitted(opId, msg.sig, executeAfter, msg.data);
        return false;
    }

    /// @dev Returns the original sender during execute replay, otherwise delegates to parent.
    function msgSender() internal view override returns (address) {
        if (_submitter != address(0)) return _submitter;
        return super.msgSender();
    }

    //----------------------------------------------------------------------------------------------
    //  View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function holdingAccounts(
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) public pure returns (HoldingAccount[] memory) {
        HoldingAccount[] memory accounts = new HoldingAccount[](4);
        accounts[0] = HoldingAccount(assetAccount, uint8(AccountType.Asset));
        accounts[1] = HoldingAccount(equityAccount, uint8(AccountType.Equity));
        accounts[2] = HoldingAccount(gainAccount, uint8(AccountType.Gain));
        accounts[3] = HoldingAccount(lossAccount, uint8(AccountType.Loss));
        return accounts;
    }

    /// @inheritdoc IHub
    function liabilityAccounts(AccountId expenseAccount, AccountId liabilityAccount)
        public
        pure
        returns (HoldingAccount[] memory)
    {
        HoldingAccount[] memory accounts = new HoldingAccount[](2);
        accounts[0] = HoldingAccount(expenseAccount, uint8(AccountType.Expense));
        accounts[1] = HoldingAccount(liabilityAccount, uint8(AccountType.Liability));
        return accounts;
    }

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

    /// @dev Extract poolId from calldata and verify sender is a manager.
    function _checkManager(bytes calldata data) private view {
        PoolId poolId = abi.decode(data[4:36], (PoolId));
        require(hubRegistry.manager(poolId, msgSender()), NotManager());
    }

    function _requireSC(PoolId poolId, ShareClassId scId) private view {
        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());
    }

    function _accrue(PoolId poolId, ShareClassId scId) private {
        if (address(feeHook) != address(0)) feeHook.accrue(poolId, scId);
    }
}

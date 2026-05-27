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
import {IManifest} from "./interfaces/IManifest.sol";

import {Auth} from "../../misc/Auth.sol";
import {d18, D18} from "../../misc/types/D18.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IMulticall} from "../../misc/interfaces/IMulticall.sol";

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
/// @notice Central pool management contract. Per-pool managers drive every state change through a
///         single, manifest-mediated entry point — {await} — so the pool's manifest is the only
///         policy boundary that matters.
///
///         The flow:
///         1. A manager calls {await} with a batch of Hub manager-method calldata. The Hub runs
///            the pool's manifest over every call, takes the longest required timelock, and
///            stores a pending op. `await` never executes anything itself; it is always async.
///         2. After the timelock, any manager calls {execute} (passing the same batch). The Hub
///            replays the calls under the original submitter's identity via {executeBatch},
///            then optionally invokes a post-batch callback on the submitter. Batches are
///            all-or-nothing — any revert reverts the whole tx and the pending op stays put.
///         3. {awaitAndExecute} folds both into one tx for the timelock==0 case so integrators
///            don't need a generic multicall to handle the common path.
///
///         All manager methods (`notifyPool`, `setRequestManager`, etc.) revert with {MustAwait}
///         when called outside an active {executeBatch} replay — they have no public surface.
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
    mapping(PoolId => uint64) public awaitNonce;
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
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "feeHook") feeHook = IFeeHook(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "shareClassManager") shareClassManager = IShareClassManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ICreatePool
    function createPool(PoolId poolId, address admin, AssetId currency) external payable auth {
        require(poolId.centrifugeId() == sender.localCentrifugeId(), InvalidPoolId());
        hubRegistry.registerPool(poolId, admin, currency);
    }

    //----------------------------------------------------------------------------------------------
    // Await flow — the only public surface for managers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function await(PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        external
        returns (uint64 nonce, bytes32 opId)
    {
        require(_submitter == address(0), AlreadyInBatch());
        return _await(msgSender(), poolId, calls, callback);
    }

    /// @inheritdoc IHub
    function execute(PoolId poolId, uint64 nonce, bytes[] calldata calls, bytes calldata callback) external payable {
        require(_submitter == address(0), AlreadyInBatch());
        require(hubRegistry.manager(poolId, msgSender()), NotManager());
        _finalize(keccak256(abi.encode(poolId, nonce, calls, callback)), calls, callback);
    }

    /// @inheritdoc IHub
    function awaitAndExecute(PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        external
        payable
        returns (uint64 nonce, bytes32 opId)
    {
        require(_submitter == address(0), AlreadyInBatch());
        (nonce, opId) = _await(msgSender(), poolId, calls, callback);
        // _await just wrote pending[opId]; finalize from the known opId without recomputing.
        _finalize(opId, calls, callback);
    }

    /// @inheritdoc IHub
    function cancel(PoolId poolId, uint64 nonce, bytes[] calldata calls, bytes calldata callback) external {
        require(hubRegistry.manager(poolId, msgSender()), NotManager());

        bytes32 opId = keccak256(abi.encode(poolId, nonce, calls, callback));
        require(pending[opId].executeAfter != 0, OperationNotPending());
        delete pending[opId];

        emit OperationCanceled(opId);
    }

    /// @inheritdoc IHub
    function setManifest(PoolId poolId, IManifest manifest_) external {
        _mustAwait();
        manifest[poolId] = manifest_;
        emit SetManifest(poolId, manifest_);
    }

    /// @inheritdoc IHub
    /// @dev Gateway-only callback invoked from {_runBatch}. Replays the batch under the submitter
    ///      context. All-or-nothing: any revert bubbles up and rolls back the whole tx.
    function executeBatch(bytes[] calldata calls) external payable {
        require(msg.sender == address(gateway), NotGateway());
        gateway.lockCallback();
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory returnData) = address(this).delegatecall(calls[i]);
            if (success) continue;
            if (returnData.length == 0) revert ExecutionFailed("");
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //
    // Manager-restricted state mutations. All require {_mustAwait} — they are only reachable
    // through {executeBatch} replaying a previously-awaited batch.
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId, address refund) external payable {
        _mustAwait();

        emit NotifyPool(centrifugeId, poolId);
        sender.sendNotifyPool{value: msgValue()}(centrifugeId, poolId, refund);
    }

    /// @inheritdoc IHub
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable
    {
        _mustAwait();
        _requireSC(poolId, scId);

        (string memory name, string memory symbol, bytes32 salt) = shareClassManager.metadata(poolId, scId);
        uint8 decimals = hubRegistry.decimals(poolId);

        emit NotifyShareClass(centrifugeId, poolId, scId);
        sender.sendNotifyShareClass{value: msgValue()}(
            centrifugeId, poolId, scId, name, symbol, decimals, salt, hook, refund
        );
    }

    /// @inheritdoc IHub
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) external payable {
        _mustAwait();

        (string memory name, string memory symbol,) = shareClassManager.metadata(poolId, scId);

        emit NotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
        sender.sendNotifyShareMetadata{value: msgValue()}(centrifugeId, poolId, scId, name, symbol, refund);
    }

    /// @inheritdoc IHub
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook, address refund)
        external
        payable
    {
        _mustAwait();

        emit UpdateShareHook(centrifugeId, poolId, scId, hook);
        sender.sendUpdateShareHook{value: msgValue()}(centrifugeId, poolId, scId, hook, refund);
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId, address refund) external payable {
        _mustAwait();

        (D18 pricePoolPerShare, uint64 computedAt) = shareClassManager.pricePoolPerShare(poolId, scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, pricePoolPerShare, computedAt);
        sender.sendNotifyPricePoolPerShare{value: msgValue()}(
            centrifugeId, poolId, scId, pricePoolPerShare, computedAt, refund
        );
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId, address refund) external payable {
        _mustAwait();

        D18 pricePoolPerAsset_ = pricePoolPerAsset(poolId, scId, assetId);
        emit NotifyAssetPrice(assetId.centrifugeId(), poolId, scId, assetId, pricePoolPerAsset_);
        sender.sendNotifyPricePoolPerAsset{value: msgValue()}(poolId, scId, assetId, pricePoolPerAsset_, refund);

        _accrue(poolId, scId);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable {
        _mustAwait();
        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable {
        _mustAwait();
        holdings.setSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable
    {
        _mustAwait();
        shareClassManager.updateMetadata(poolId, scId, name, symbol);
    }

    /// @inheritdoc IHub
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable {
        _mustAwait();
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
        _mustAwait();

        hubRegistry.setHubRequestManager(poolId, centrifugeId, hubManager);

        emit SetSpokeRequestManager(centrifugeId, poolId, spokeManager);
        sender.sendSetRequestManager{value: msgValue()}(centrifugeId, poolId, spokeManager, refund);
    }

    /// @inheritdoc IHub
    function updateBalanceSheetManager(PoolId poolId, uint16 centrifugeId, bytes32 who, bool canManage, address refund)
        external
        payable
    {
        _mustAwait();

        emit UpdateBalanceSheetManager(centrifugeId, poolId, who, canManage);
        sender.sendUpdateBalanceSheetManager{value: msgValue()}(centrifugeId, poolId, who, canManage, refund);
    }

    /// @inheritdoc IHub
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId)
    {
        _mustAwait();
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
        _mustAwait();
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
        _mustAwait();
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
        _mustAwait();
        _requireSC(poolId, scId);

        emit UpdateContract(centrifugeId, poolId, scId, target, payload);
        sender.sendTrustedContractUpdate{value: msgValue()}(
            centrifugeId, poolId, scId, target, payload, extraGasLimit, refund
        );
    }

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare, uint64 computedAt)
        external
        payable
    {
        _mustAwait();
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
        _mustAwait();

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
        _mustAwait();

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
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external payable {
        _mustAwait();

        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);
        _updateAccountingValue(poolId, scId, assetId, isPositive, diff);

        holdings.callOnSyncSnapshot(poolId, scId, assetId.centrifugeId());
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable
    {
        _mustAwait();
        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IHub
    function updateHoldingIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability)
        external
        payable
    {
        _mustAwait();
        holdings.updateIsLiability(poolId, scId, assetId, isLiability);
    }

    /// @inheritdoc IHub
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable
    {
        _mustAwait();

        require(accounting.exists(poolId, accountId), IAccounting.AccountDoesNotExist());

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external payable {
        _mustAwait();
        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable {
        _mustAwait();
        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IHub
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits)
        external
        payable
    {
        _mustAwait();

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
        _mustAwait();

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
        _mustAwait();

        emit UpdateGatewayManager(centrifugeId, poolId, who, canManage);
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
    // Accounting methods
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

    //----------------------------------------------------------------------------------------------
    // View methods
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
    // Internal: await pipeline
    //----------------------------------------------------------------------------------------------

    /// @dev Manifest run + pending-op write. Factored out so {await} and {awaitAndExecute} share
    ///      this without blowing the stack-too-deep limit on the {OperationSubmitted} emit.
    function _await(address submitter, PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        internal
        returns (uint64 nonce, bytes32 opId)
    {
        require(hubRegistry.manager(poolId, submitter), NotManager());
        require(calls.length != 0, EmptyBatch());

        // Validate every call's selector + poolId, run the manifest on each, take the max delay.
        // Blocking the batching selectors here is what makes the manifest binding — otherwise an
        // operator could wrap a manager call in `multicall` and skip the check.
        uint48 maxTimelock = _runManifest(poolId, submitter, calls);

        // Per-pool nonce makes opId unique even for byte-identical batches, so two awaits with
        // the same payload don't collide in `pending` storage.
        nonce = ++awaitNonce[poolId];
        opId = keccak256(abi.encode(poolId, nonce, calls, callback));
        uint48 executeAfter = uint48(block.timestamp) + maxTimelock;
        pending[opId] = PendingOp(executeAfter, submitter);
        emit OperationSubmitted(opId, poolId, submitter, nonce, executeAfter, calls, callback);
    }

    /// @dev Lookup + replay by opId. Used by {execute} (after hashing) and {awaitAndExecute}
    ///      (skips the hash since `_await` just wrote the slot).
    function _finalize(bytes32 opId, bytes[] calldata calls, bytes calldata callback) internal {
        PendingOp memory op = pending[opId];
        require(op.executeAfter != 0, OperationNotPending());
        require(block.timestamp >= op.executeAfter, TimelockNotReady(op.executeAfter));
        // Delete BEFORE _runBatch: if _runBatch reverts the tx unwinds and the pending op stays
        // put, so the batch can be retried (useful when execute OOGs).
        delete pending[opId];

        _runBatch(op.submitter, calls, callback);
        emit OperationExecuted(opId);
    }

    /// @dev Walk the batch through the pool's manifest, returning the longest required delay.
    function _runManifest(PoolId poolId, address submitter, bytes[] calldata calls)
        internal
        returns (uint48 maxTimelock)
    {
        IManifest m = manifest[poolId];
        for (uint256 i; i < calls.length; i++) {
            require(_callPoolId(calls[i]) == poolId, PoolIdMismatch());
            _validateBatchSelector(calls[i]);
            if (address(m) == address(0)) continue;
            uint48 t = m.check(poolId, submitter, calls[i]);
            if (t > maxTimelock) maxTimelock = t;
        }
    }

    /// @dev Set the submitter context, drive the batch through {executeBatch} via the gateway
    ///      (so cross-chain payments aggregate), then clear the context and invoke the post-batch
    ///      callback. The clear happens BEFORE the callback so the callback may recursively call
    ///      {await} — see the matching guard at the top of {await}.
    function _runBatch(address submitter, bytes[] calldata calls, bytes calldata callback) private {
        _submitter = submitter;
        gateway.withBatch{value: msg.value}(
            abi.encodeWithSelector(IHub.executeBatch.selector, calls), submitter
        );
        _submitter = address(0);

        if (callback.length == 0) return;

        (bool ok, bytes memory ret) = submitter.call(callback);
        if (ok) return;
        if (ret.length == 0) revert CallbackFailed("");
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }

    /// @dev Manager methods reject direct calls — must arrive inside an {executeBatch} replay.
    function _mustAwait() private view {
        require(_submitter != address(0), MustAwait());
    }

    /// @dev Decode a call's first argument as a PoolId.
    function _callPoolId(bytes calldata data) private pure returns (PoolId) {
        require(data.length >= 36, PoolIdMismatch()); // 4-byte selector + 32-byte first arg
        return abi.decode(data[4:36], (PoolId));
    }

    /// @dev Reject selectors that would nest another batching frame inside the replay.
    function _validateBatchSelector(bytes calldata data) private pure {
        bytes4 sel = bytes4(data[:4]);
        require(
            sel != IMulticall.multicall.selector && sel != IHub.await.selector
                && sel != IHub.execute.selector && sel != IHub.cancel.selector,
            ForbiddenSelector()
        );
    }

    /// @dev Returns the active submitter while {executeBatch} is replaying, otherwise the parent
    ///      resolution. The `_submitter != 0` window is tight: it's set in {_runBatch} and cleared
    ///      before the post-batch callback fires, so neither the callback nor any nested
    ///      `hub.await` it triggers can inherit the prior submitter.
    function msgSender() internal view override returns (address) {
        if (_submitter != address(0)) return _submitter;
        return super.msgSender();
    }

    //----------------------------------------------------------------------------------------------
    // Internal: accounting helpers
    //----------------------------------------------------------------------------------------------

    function _updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        internal
    {
        if (diff == 0) return;
        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType a = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType b = isLiability ? AccountType.Liability : AccountType.Equity;
        _journal(poolId, scId, assetId, isPositive, diff, a, b);
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
    // Internal: small utilities
    //----------------------------------------------------------------------------------------------

    function _requireSC(PoolId poolId, ShareClassId scId) private view {
        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());
    }

    function _accrue(PoolId poolId, ShareClassId scId) private {
        if (address(feeHook) != address(0)) feeHook.accrue(poolId, scId);
    }
}

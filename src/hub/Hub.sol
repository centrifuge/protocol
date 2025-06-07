// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IValuation} from "src/common/interfaces/IValuation.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IHubGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IHubMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IHubGuardianActions} from "src/common/interfaces/IGuardianActions.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ISnapshotHook} from "src/common/interfaces/ISnapshotHook.sol";
import {RequestCallbackMessageLib} from "src/common/libraries/RequestCallbackMessageLib.sol";

import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IHub, VaultUpdateKind} from "src/hub/interfaces/IHub.sol";
import {IHubHelpers} from "src/hub/interfaces/IHubHelpers.sol";

/// @title  Hub
/// @notice Central pool management contract, that brings together all functions in one place.
///         Pools can assign hub managers which have full rights over all actions.
///
///         Also acts as the central contract that routes messages from other chains to the Hub contracts.
contract Hub is Multicall, Auth, Recoverable, IHub, IHubGatewayHandler, IHubGuardianActions {
    using MathLib for uint256;
    using RequestCallbackMessageLib for *;

    IHubRegistry public immutable hubRegistry;

    IGateway public gateway;
    IHoldings public holdings;
    IHubHelpers public hubHelpers;
    IAccounting public accounting;
    IHubMessageSender public sender;
    IShareClassManager public shareClassManager;

    constructor(
        IGateway gateway_,
        IHoldings holdings_,
        IHubHelpers hubHelpers_,
        IAccounting accounting_,
        IHubRegistry hubRegistry_,
        IShareClassManager shareClassManager_,
        address deployer
    ) Auth(deployer) {
        gateway = gateway_;
        holdings = holdings_;
        hubHelpers = hubHelpers_;
        accounting = accounting_;
        hubRegistry = hubRegistry_;
        shareClassManager = shareClassManager_;
    }

    modifier payTransaction() {
        _startTransactionPayment();
        _;
        _endTransactionPayment();
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function file(bytes32 what, address data) external {
        _auth();

        if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "hubHelpers") hubHelpers = IHubHelpers(data);
        else if (what == "accounting") accounting = IAccounting(data);
        else if (what == "shareClassManager") shareClassManager = IShareClassManager(data);
        else if (what == "gateway") gateway = IGateway(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all messages sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatching();
            gateway.startTransactionPayment{value: msg.value}(msg.sender);
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.endBatching();
            gateway.endTransactionPayment();
        }
    }

    /// @inheritdoc IHubGuardianActions
    function createPool(PoolId poolId, address admin, AssetId currency) external payable {
        _auth();

        require(poolId.centrifugeId() == sender.localCentrifugeId(), InvalidPoolId());
        hubRegistry.registerPool(poolId, admin, currency);
    }

    //----------------------------------------------------------------------------------------------
    // Permissionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        payable
        payTransaction
    {
        (uint128 totalPayoutShareAmount, uint128 totalPaymentAssetAmount, uint128 cancelledAssetAmount) =
            hubHelpers.notifyDeposit(poolId, scId, assetId, investor, maxClaims);

        if (totalPaymentAssetAmount > 0 || cancelledAssetAmount > 0) {
            sender.sendRequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledDepositRequest(
                    poolId.raw(),
                    scId.raw(),
                    investor,
                    assetId.raw(),
                    totalPaymentAssetAmount,
                    totalPayoutShareAmount,
                    cancelledAssetAmount
                ).serialize()
            );
        }
    }

    /// @inheritdoc IHub
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        payable
        payTransaction
    {
        (uint128 totalPayoutAssetAmount, uint128 totalPaymentShareAmount, uint128 cancelledShareAmount) =
            hubHelpers.notifyRedeem(poolId, scId, assetId, investor, maxClaims);

        if (totalPaymentShareAmount > 0 || cancelledShareAmount > 0) {
            sender.sendRequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest(
                    poolId.raw(),
                    scId.raw(),
                    investor,
                    assetId.raw(),
                    totalPayoutAssetAmount,
                    totalPaymentShareAmount,
                    cancelledShareAmount
                ).serialize()
            );
        }
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId) external payable payTransaction {
        _isManager(poolId);

        emit NotifyPool(centrifugeId, poolId);
        sender.sendNotifyPool(centrifugeId, poolId);
    }

    /// @inheritdoc IHub
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol, bytes32 salt) = shareClassManager.metadata(scId);
        uint8 decimals = hubRegistry.decimals(poolId);

        emit NotifyShareClass(centrifugeId, poolId, scId);
        sender.sendNotifyShareClass(centrifugeId, poolId, scId, name, symbol, decimals, salt, hook);
    }

    /// @inheritdoc IHub
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId) public payable payTransaction {
        _isManager(poolId);

        (string memory name, string memory symbol,) = shareClassManager.metadata(scId);

        emit NotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
        sender.sendNotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
    }

    /// @inheritdoc IHub
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook)
        public
        payable
        payTransaction
    {
        _isManager(poolId);

        emit UpdateShareHook(centrifugeId, poolId, scId, hook);
        sender.sendUpdateShareHook(centrifugeId, poolId, scId, hook);
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) public payable payTransaction {
        _isManager(poolId);

        (, D18 poolPerShare) = shareClassManager.metrics(scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, poolPerShare);
        sender.sendNotifyPricePoolPerShare(centrifugeId, poolId, scId, poolPerShare);
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId) public payable payTransaction {
        _isManager(poolId);
        D18 pricePoolPerAsset = hubHelpers.pricePoolPerAsset(poolId, scId, assetId);
        emit NotifyAssetPrice(assetId.centrifugeId(), poolId, scId, assetId, pricePoolPerAsset);
        sender.sendNotifyPricePoolPerAsset(poolId, scId, assetId, pricePoolPerAsset);
    }

    /// @inheritdoc IHub
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        emit SetMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
        sender.sendMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
    }

    /// @inheritdoc IHub
    function setMaxSharePriceAge(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint64 maxPriceAge)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        emit SetMaxSharePriceAge(centrifugeId, poolId, scId, maxPriceAge);
        sender.sendMaxSharePriceAge(centrifugeId, poolId, scId, maxPriceAge);
    }

    /// @inheritdoc IHub
    function setQueue(PoolId poolId, ShareClassId scId, bool enabled) public payable {
        _isManager(poolId);

        sender.sendSetQueue(poolId, scId, enabled);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable {
        _isManager(poolId);

        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external payable {
        _isManager(poolId);

        holdings.setSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
        payable
    {
        _isManager(poolId);

        shareClassManager.updateMetadata(poolId, scId, name, symbol);
    }

    /// @inheritdoc IHub
    function updateHubManager(PoolId poolId, address who, bool canManage) external payable {
        _isManager(poolId);

        hubRegistry.updateManager(poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function updateBalanceSheetManager(uint16 centrifugeId, PoolId poolId, bytes32 who, bool canManage)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        sender.sendUpdateBalanceSheetManager(centrifugeId, poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        payable
        returns (ShareClassId scId)
    {
        _isManager(poolId);

        return shareClassManager.addShareClass(poolId, name, symbol, salt);
    }

    /// @inheritdoc IHub
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount
    ) external payable payTransaction returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount) {
        _isManager(poolId);
        D18 pricePoolPerAsset = hubHelpers.pricePoolPerAsset(poolId, scId, depositAssetId);
        (pendingAssetAmount, approvedPoolAmount) = shareClassManager.approveDeposits(
            poolId, scId, depositAssetId, nowDepositEpochId, approvedAssetAmount, pricePoolPerAsset
        );

        sender.sendRequestCallback(
            poolId,
            scId,
            depositAssetId,
            RequestCallbackMessageLib.ApprovedDeposits(
                poolId.raw(), scId.raw(), depositAssetId.raw(), approvedAssetAmount, pricePoolPerAsset.raw()
            ).serialize()
        );
    }

    /// @inheritdoc IHub
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount
    ) external payable returns (uint128 pendingShareAmount) {
        _isManager(poolId);

        D18 price = hubHelpers.pricePoolPerAsset(poolId, scId, payoutAssetId);
        (pendingShareAmount) =
            shareClassManager.approveRedeems(poolId, scId, payoutAssetId, nowRedeemEpochId, approvedShareAmount, price);
    }

    /// @inheritdoc IHub
    function issueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare
    )
        external
        payable
        payTransaction
        returns (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount)
    {
        _isManager(poolId);

        (issuedShareAmount, depositAssetAmount, depositPoolAmount) =
            shareClassManager.issueShares(poolId, scId, depositAssetId, nowIssueEpochId, navPoolPerShare);

        sender.sendRequestCallback(
            poolId,
            scId,
            depositAssetId,
            RequestCallbackMessageLib.IssuedShares(poolId.raw(), scId.raw(), issuedShareAmount, navPoolPerShare.raw())
                .serialize()
        );
    }

    /// @inheritdoc IHub
    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare
    )
        external
        payable
        payTransaction
        returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount)
    {
        _isManager(poolId);

        (revokedShareAmount, payoutAssetAmount, payoutPoolAmount) =
            shareClassManager.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, navPoolPerShare);

        sender.sendRequestCallback(
            poolId,
            scId,
            payoutAssetId,
            RequestCallbackMessageLib.RevokedShares(
                poolId.raw(),
                scId.raw(),
                payoutAssetId.raw(),
                payoutAssetAmount,
                revokedShareAmount,
                navPoolPerShare.raw()
            ).serialize()
        );
    }

    /// @inheritdoc IHub
    function forceCancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        uint128 cancelledAssetAmount =
            shareClassManager.forceCancelDepositRequest(poolId, scId, investor, depositAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledAssetAmount > 0) {
            sender.sendRequestCallback(
                poolId,
                scId,
                depositAssetId,
                RequestCallbackMessageLib.FulfilledDepositRequest(
                    poolId.raw(), scId.raw(), investor, depositAssetId.raw(), 0, 0, cancelledAssetAmount
                ).serialize()
            );
        }
    }

    /// @inheritdoc IHub
    function forceCancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        uint128 cancelledShareAmount = shareClassManager.forceCancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledShareAmount > 0) {
            sender.sendRequestCallback(
                poolId,
                scId,
                payoutAssetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest(
                    poolId.raw(), scId.raw(), investor, payoutAssetId.raw(), 0, 0, cancelledShareAmount
                ).serialize()
            );
        }
    }

    /// @inheritdoc IHub
    function updateRestriction(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes calldata payload)
        external
        payable
        payTransaction
    {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateRestriction(centrifugeId, poolId, scId, payload);
        sender.sendUpdateRestriction(centrifugeId, poolId, scId, payload);
    }

    /// @inheritdoc IHub
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind
    ) external payable payTransaction {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateVault(poolId, scId, assetId, vaultOrFactory, kind);
        sender.sendUpdateVault(poolId, scId, assetId, vaultOrFactory, kind);
    }

    /// @inheritdoc IHub
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload
    ) external payable payTransaction {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateContract(centrifugeId, poolId, scId, target, payload);
        sender.sendUpdateContract(centrifugeId, poolId, scId, target, payload);
    }

    /// @inheritdoc IHub
    function request(PoolId poolId, ShareClassId scId, bytes calldata payload) external payable payTransaction {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        // TODO: parse requset payload
    }

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 navPoolPerShare) public payable {
        _isManager(poolId);

        shareClassManager.updateSharePrice(poolId, scId, navPoolPerShare);
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
        _isManager(poolId);

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
            hubHelpers.holdingAccounts(assetAccount, equityAccount, gainAccount, lossAccount)
        );

        // If increase/decrease was called before initialize, we add journal entries for this
        hubHelpers.updateAccountingAmount(poolId, scId, assetId, true, holdings.value(poolId, scId, assetId));
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
        _isManager(poolId);

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        require(expenseAccount != liabilityAccount, IHub.InvalidAccountCombination());
        require(
            accounting.exists(poolId, expenseAccount) && accounting.exists(poolId, liabilityAccount),
            IAccounting.AccountDoesNotExist()
        );

        holdings.initialize(
            poolId, scId, assetId, valuation, true, hubHelpers.liabilityAccounts(expenseAccount, liabilityAccount)
        );

        // If increase/decrease was called before initialize, we add journal entries for this
        hubHelpers.updateAccountingAmount(poolId, scId, assetId, true, holdings.value(poolId, scId, assetId));
    }

    /// @inheritdoc IHub
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) public payable {
        _isManager(poolId);

        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);
        hubHelpers.updateAccountingValue(poolId, scId, assetId, isPositive, diff);
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        payable
    {
        _isManager(poolId);

        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IHub
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        payable
    {
        _isManager(poolId);

        require(accounting.exists(poolId, accountId), IAccounting.AccountDoesNotExist());

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) public payable {
        _isManager(poolId);

        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable {
        _isManager(poolId);

        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IHub
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external {
        _isManager(poolId);

        accounting.unlock(poolId);
        accounting.addJournal(debits, credits);
        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubGatewayHandler
    function registerAsset(AssetId assetId, uint8 decimals) external {
        _auth();

        hubRegistry.registerAsset(assetId, decimals);
    }

    /// @inheritdoc IHubGatewayHandler
    function depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount)
        external
    {
        _auth();

        shareClassManager.requestDeposit(poolId, scId, amount, investor, depositAssetId);
    }

    /// @inheritdoc IHubGatewayHandler
    function redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount)
        external
    {
        _auth();

        shareClassManager.requestRedeem(poolId, scId, amount, investor, payoutAssetId);
    }

    /// @inheritdoc IHubGatewayHandler
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
    {
        _auth();

        uint128 cancelledAssetAmount = shareClassManager.cancelDepositRequest(poolId, scId, investor, depositAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledAssetAmount > 0) {
            sender.sendRequestCallback(
                poolId,
                scId,
                depositAssetId,
                RequestCallbackMessageLib.FulfilledDepositRequest(
                    poolId.raw(), scId.raw(), investor, depositAssetId.raw(), 0, 0, cancelledAssetAmount
                ).serialize()
            );
        }
    }

    /// @inheritdoc IHubGatewayHandler
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) external {
        _auth();

        uint128 cancelledShareAmount = shareClassManager.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledShareAmount > 0) {
            sender.sendRequestCallback(
                poolId,
                scId,
                payoutAssetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest(
                    poolId.raw(), scId.raw(), investor, payoutAssetId.raw(), 0, 0, cancelledShareAmount
                ).serialize()
            );
        }
    }

    /// @inheritdoc IHubGatewayHandler
    function updateHoldingAmount(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) external {
        _auth();

        uint128 value = isIncrease
            ? holdings.increase(poolId, scId, assetId, pricePoolPerAsset, amount)
            : holdings.decrease(poolId, scId, assetId, pricePoolPerAsset, amount);

        if (holdings.isInitialized(poolId, scId, assetId)) {
            hubHelpers.updateAccountingAmount(poolId, scId, assetId, isIncrease, value);
        }

        holdings.setSnapshot(poolId, scId, centrifugeId, isSnapshot, nonce);
    }

    /// @inheritdoc IHubGatewayHandler
    function updateShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        uint128 amount,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce
    ) external {
        _auth();

        shareClassManager.updateShares(centrifugeId, poolId, scId, amount, isIssuance);

        holdings.setSnapshot(poolId, scId, centrifugeId, isSnapshot, nonce);
    }

    /// @inheritdoc IHubGatewayHandler
    function initiateTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    ) external {
        _auth();

        emit ForwardTransferShares(centrifugeId, poolId, scId, receiver, amount);
        sender.sendExecuteTransferShares(centrifugeId, poolId, scId, receiver, amount);
    }

    //----------------------------------------------------------------------------------------------
    //  Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Ensure the sender is authorized
    function _auth() internal auth {}

    /// @dev Ensure the method can be used without reentrancy issues, and the sender is a pool admin
    function _isManager(PoolId poolId) internal protected {
        require(hubRegistry.manager(poolId, msg.sender), IHub.NotManager());
    }

    /// @notice Send native tokens to the gateway for transaction payment if it's not in a multicall.
    function _startTransactionPayment() internal {
        if (!gateway.isBatching()) {
            gateway.startTransactionPayment{value: msg.value}(msg.sender);
        }
    }

    function _endTransactionPayment() internal {
        if (!gateway.isBatching()) {
            gateway.endTransactionPayment();
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {ConversionLib} from "src/misc/libraries/ConversionLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {MessageLib, UpdateContractType, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {IHubGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IHoldings, Holding, HoldingAccount} from "src/hub/interfaces/IHoldings.sol";
import {IHub, AccountType} from "src/hub/interfaces/IHub.sol";

// @inheritdoc IHub
contract Hub is Multicall, Auth, Recoverable, IHub, IHubGatewayHandler {
    using MathLib for uint256;

    IGateway public gateway;
    IHoldings public holdings;
    IAccounting public accounting;
    IHubRegistry public hubRegistry;
    IPoolMessageSender public sender;
    IShareClassManager public shareClassManager;
    ITransientValuation public transientValuation;

    constructor(
        IShareClassManager shareClassManager_,
        IHubRegistry hubRegistry_,
        IAccounting accounting_,
        IHoldings holdings_,
        IGateway gateway_,
        ITransientValuation transientValuation_,
        address deployer
    ) Auth(deployer) {
        shareClassManager = shareClassManager_;
        hubRegistry = hubRegistry_;
        accounting = accounting_;
        holdings = holdings_;
        gateway = gateway_;
        transientValuation = transientValuation_;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function file(bytes32 what, address data) external {
        _auth();

        if (what == "sender") sender = IPoolMessageSender(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "hubRegistry") hubRegistry = IHubRegistry(data);
        else if (what == "shareClassManager") shareClassManager = IShareClassManager(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "accounting") accounting = IAccounting(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all messages sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatching();
            gateway.payTransaction{value: msg.value}(msg.sender);
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.endBatching();
        }
    }

    /// @inheritdoc IHub
    function createPool(PoolId poolId, address admin, AssetId currency) external payable {
        _auth();

        require(poolId.centrifugeId() == sender.localCentrifugeId(), InvalidPoolId());
        hubRegistry.registerPool(poolId, admin, currency);
    }

    //----------------------------------------------------------------------------------------------
    // Permissionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        payable
    {
        _pay();

        uint128 totalPayoutShareAmount;
        uint128 totalPaymentAssetAmount;
        uint128 totalCancelledAssetAmount;

        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelledAssetAmount, bool canClaimAgain) =
                shareClassManager.claimDeposit(poolId, scId, investor, assetId);

            totalPayoutShareAmount += payoutShareAmount;
            totalPaymentAssetAmount += paymentAssetAmount;
            totalCancelledAssetAmount = cancelledAssetAmount;

            if (!canClaimAgain) {
                break;
            }
        }

        sender.sendFulfilledDepositRequest(
            poolId, scId, assetId, investor, totalPaymentAssetAmount, totalPayoutShareAmount
        );

        // If cancellation was queued, notify about delayed cancellation
        if (totalCancelledAssetAmount > 0) {
            sender.sendFulfilledCancelDepositRequest(poolId, scId, assetId, investor, totalCancelledAssetAmount);
        }
    }

    /// @inheritdoc IHub
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        payable
    {
        _pay();

        uint128 totalPayoutAssetAmount;
        uint128 totalPaymentShareAmount;
        uint128 totalCancelledShareAmount;

        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelledShareAmount, bool canClaimAgain) =
                shareClassManager.claimRedeem(poolId, scId, investor, assetId);

            totalPayoutAssetAmount += payoutAssetAmount;
            totalPaymentShareAmount += paymentShareAmount;
            totalCancelledShareAmount = cancelledShareAmount;

            if (!canClaimAgain) {
                break;
            }
        }

        sender.sendFulfilledRedeemRequest(
            poolId, scId, assetId, investor, totalPayoutAssetAmount, totalPaymentShareAmount
        );

        // If cancellation was queued, notify about delayed cancellation
        if (totalCancelledShareAmount > 0) {
            sender.sendFulfilledCancelRedeemRequest(poolId, scId, assetId, investor, totalCancelledShareAmount);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------
    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId) external payable {
        _protectedAndPaid(poolId);

        emit NotifyPool(centrifugeId, poolId);
        sender.sendNotifyPool(centrifugeId, poolId);
    }

    /// @inheritdoc IHub
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook) external payable {
        _protectedAndPaid(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol, bytes32 salt) = shareClassManager.metadata(scId);
        uint8 decimals = hubRegistry.decimals(poolId);

        emit NotifyShareClass(centrifugeId, poolId, scId);
        sender.sendNotifyShareClass(centrifugeId, poolId, scId, name, symbol, decimals, salt, hook);
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) public payable {
        _protectedAndPaid(poolId);

        (, D18 poolPerShare) = shareClassManager.metrics(scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, poolPerShare);
        sender.sendNotifyPricePoolPerShare(centrifugeId, poolId, scId, poolPerShare);
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId) public payable {
        _protectedAndPaid(poolId);
        D18 pricePoolPerAsset = _pricePoolPerAsset(poolId, scId, assetId);
        emit NotifyAssetPrice(assetId.centrifugeId(), poolId, scId, assetId, pricePoolPerAsset);
        sender.sendNotifyPricePoolPerAsset(poolId, scId, assetId, pricePoolPerAsset);
    }

    /// @inheritdoc IHub
    function sendTriggerSubmitQueuedShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId) public payable {
        _protectedAndPaid(poolId);

        sender.sendTriggerSubmitQueuedShares(centrifugeId, poolId, scId);
    }

    /// @inheritdoc IHub
    function sendTriggerSubmitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) public payable {
        _protectedAndPaid(poolId);

        sender.sendTriggerSubmitQueuedAssets(poolId, scId, assetId);
    }

    /// @inheritdoc IHub
    function sendSetSharesQueue(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bool enabled) public payable {
        _protectedAndPaid(poolId);

        sender.sendSetSharesQueue(centrifugeId, poolId, scId, enabled);
    }

    /// @inheritdoc IHub
    function sendSetAssetsQueue(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bool enabled) public payable {
        _protectedAndPaid(poolId);

        sender.sendSetAssetsQueue(centrifugeId, poolId, scId, enabled);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external payable {
        _protected(poolId);

        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function updateManager(PoolId poolId, address who, bool canManage) external payable {
        _protected(poolId);

        hubRegistry.updateManager(poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function addShareClass(
        PoolId poolId,
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        bytes calldata data
    ) external payable {
        _protected(poolId);

        shareClassManager.addShareClass(poolId, name, symbol, salt, data);
    }

    /// @inheritdoc IHub
    function approveDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount
    ) external payable returns (uint128 pendingAssetAmount, uint128 approvedPoolAmount) {
        _protectedAndPaid(poolId);

        (pendingAssetAmount, approvedPoolAmount) = shareClassManager.approveDeposits(
            poolId,
            scId,
            depositAssetId,
            nowDepositEpochId,
            approvedAssetAmount,
            _pricePoolPerAsset(poolId, scId, depositAssetId)
        );

        sender.sendApprovedDeposits(poolId, scId, depositAssetId, approvedAssetAmount);
    }

    /// @inheritdoc IHub
    function approveRedeems(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount
    ) external payable returns (uint128 pendingShareAmount) {
        _protected(poolId);

        (pendingShareAmount) = shareClassManager.approveRedeems(
            poolId,
            scId,
            payoutAssetId,
            nowRedeemEpochId,
            approvedShareAmount,
            _pricePoolPerAsset(poolId, scId, payoutAssetId)
        );
    }

    /// @inheritdoc IHub
    function issueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint32 nowIssueEpochId,
        D18 navPoolPerShare
    ) external payable returns (uint128 issuedShareAmount, uint128 depositAssetAmount, uint128 depositPoolAmount) {
        _protected(poolId);

        (issuedShareAmount, depositAssetAmount, depositPoolAmount) =
            shareClassManager.issueShares(poolId, scId, depositAssetId, nowIssueEpochId, navPoolPerShare);
    }

    /// @inheritdoc IHub
    function revokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId,
        D18 navPoolPerShare
    ) external payable returns (uint128 revokedShareAmount, uint128 payoutAssetAmount, uint128 payoutPoolAmount) {
        _protectedAndPaid(poolId);

        (revokedShareAmount, payoutAssetAmount, payoutPoolAmount) =
            shareClassManager.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, navPoolPerShare);

        sender.sendRevokedShares(poolId, scId, payoutAssetId, payoutAssetAmount);
    }

    /// @inheritdoc IHub
    function updateRestriction(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes calldata payload)
        external
        payable
    {
        _protectedAndPaid(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateRestriction(centrifugeId, poolId, scId, payload);
        sender.sendUpdateRestriction(centrifugeId, poolId, scId, payload);
    }

    /// @inheritdoc IHub
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload
    ) external payable {
        _protectedAndPaid(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateContract(centrifugeId, poolId, scId, target, payload);
        sender.sendUpdateContract(centrifugeId, poolId, scId, target, payload);
    }

    /// @inheritdoc IHub
    function updatePricePerShare(PoolId poolId, ShareClassId scId, D18 navPoolPerShare) public payable {
        _protected(poolId);

        shareClassManager.updatePricePerShare(poolId, scId, navPoolPerShare);
    }

    /// @inheritdoc IHub
    function createHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IERC7726 valuation,
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId lossAccount,
        AccountId gainAccount
    ) external payable {
        _protected(poolId);

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        require(
            accounting.exists(poolId, assetAccount) && accounting.exists(poolId, equityAccount)
                && accounting.exists(poolId, lossAccount) && accounting.exists(poolId, gainAccount),
            IAccounting.AccountDoesNotExist()
        );

        HoldingAccount[] memory accounts = new HoldingAccount[](4);
        accounts[0] = HoldingAccount(assetAccount, uint8(AccountType.Asset));
        accounts[1] = HoldingAccount(equityAccount, uint8(AccountType.Equity));
        accounts[2] = HoldingAccount(lossAccount, uint8(AccountType.Loss));
        accounts[3] = HoldingAccount(gainAccount, uint8(AccountType.Gain));

        holdings.create(poolId, scId, assetId, valuation, false, accounts);
    }

    /// @inheritdoc IHub
    function createLiability(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IERC7726 valuation,
        AccountId expenseAccount,
        AccountId liabilityAccount
    ) external payable {
        _protected(poolId);

        require(hubRegistry.isRegistered(assetId), IHubRegistry.AssetNotFound());
        require(
            accounting.exists(poolId, expenseAccount) && accounting.exists(poolId, liabilityAccount),
            IAccounting.AccountDoesNotExist()
        );

        HoldingAccount[] memory accounts = new HoldingAccount[](2);
        accounts[0] = HoldingAccount(expenseAccount, uint8(AccountType.Expense));
        accounts[1] = HoldingAccount(liabilityAccount, uint8(AccountType.Liability));

        holdings.create(poolId, scId, assetId, valuation, true, accounts);
    }

    /// @inheritdoc IHub
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) public payable {
        _protected(poolId);

        accounting.unlock(poolId);

        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);

        // NOTE: Safe a diff=0 update gas cost
        if (isPositive && diff > 0) {
            if (holdings.isLiability(poolId, scId, assetId)) {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Liability)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Expense)), diff);
            } else {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset)), diff);
            }
        } else {
            if (holdings.isLiability(poolId, scId, assetId)) {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Expense)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Liability)), diff);
            } else {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss)), diff);
            }
        }

        accounting.lock();
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation)
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

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) public payable {
        _protected(poolId);

        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external payable {
        _protected(poolId);

        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IHub
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external {
        _protected(poolId);

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
            sender.sendFulfilledCancelDepositRequest(poolId, scId, depositAssetId, investor, cancelledAssetAmount);
        }
    }

    /// @inheritdoc IHubGatewayHandler
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) external {
        _auth();

        uint128 cancelledShareAmount = shareClassManager.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledShareAmount > 0) {
            sender.sendFulfilledCancelRedeemRequest(poolId, scId, payoutAssetId, investor, cancelledShareAmount);
        }
    }

    /// @inheritdoc IHubGatewayHandler
    function updateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease
    ) external {
        _auth();

        accounting.unlock(poolId);

        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType debitAccountType = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType creditAccountType = isLiability ? AccountType.Liability : AccountType.Equity;

        if (isIncrease) {
            uint128 value = holdings.increase(poolId, scId, assetId, pricePoolPerAsset, amount);
            accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(debitAccountType)), value);
            accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(creditAccountType)), value);
        } else {
            uint128 value = holdings.decrease(poolId, scId, assetId, pricePoolPerAsset, amount);
            accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(creditAccountType)), value);
            accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(debitAccountType)), value);
        }

        accounting.lock();
    }

    /// @inheritdoc IHubGatewayHandler
    function increaseShareIssuance(PoolId poolId, ShareClassId scId, D18, /*pricePerShare*/ uint128 amount) external {
        _auth();

        shareClassManager.increaseShareClassIssuance(poolId, scId, amount);
    }

    /// @inheritdoc IHubGatewayHandler
    function decreaseShareIssuance(PoolId poolId, ShareClassId scId, D18, /*pricePerShare*/ uint128 amount) external {
        _auth();

        shareClassManager.decreaseShareClassIssuance(poolId, scId, amount);
    }

    //----------------------------------------------------------------------------------------------
    //  Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Ensure the sender is authorized
    function _auth() internal auth {}

    /// @dev Ensure the method can be used without reentrancy issues, and the sender is a pool admin
    function _protected(PoolId poolId) internal protected {
        require(hubRegistry.manager(poolId, msg.sender), IHub.NotManager());
    }

    /// @dev Ensure the sender is authorized
    function _protectedAndPaid(PoolId poolId) internal {
        _protected(poolId);
        _pay();
    }

    /// @notice Send native tokens to the gateway for transaction payment if it's not in a multicall.
    function _pay() internal {
        if (!gateway.isBatching()) {
            gateway.payTransaction{value: msg.value}(msg.sender);
        }
    }

    function _pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) internal view returns (D18) {
        AssetId poolCurrency = hubRegistry.currency(poolId);
        // NOTE: We assume symmetric prices are provided by holdings valuation
        IERC7726 valuation = holdings.valuation(poolId, scId, assetId);

        // Retrieve amount of 1 asset unit in pool currency
        uint128 assetUnitAmount = (10 ** hubRegistry.decimals(assetId.raw())).toUint128();
        uint128 poolUnitAmount = (10 ** hubRegistry.decimals(poolCurrency.raw())).toUint128();
        uint128 poolAmountPerAsset =
            valuation.getQuote(assetUnitAmount, assetId.addr(), poolCurrency.addr()).toUint128();

        // Retrieve price by normalizing by pool denomination
        return d18(poolAmountPerAsset, poolUnitAmount);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHoldings} from "./interfaces/IHoldings.sol";
import {IHubHelpers} from "./interfaces/IHubHelpers.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IHub, VaultUpdateKind} from "./interfaces/IHub.sol";
import {IAccounting, JournalEntry} from "./interfaces/IAccounting.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";
import {IShareClassManager} from "./interfaces/IShareClassManager.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {Multicall, IMulticall} from "../misc/Multicall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {AccountId} from "../common/types/AccountId.sol";
import {IAdapter} from "../common/interfaces/IAdapter.sol";
import {IGateway} from "../common/interfaces/IGateway.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";
import {IMultiAdapter} from "../common/interfaces/IMultiAdapter.sol";
import {ISnapshotHook} from "../common/interfaces/ISnapshotHook.sol";
import {IHubMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {IHubGatewayHandler} from "../common/interfaces/IGatewayHandlers.sol";
import {IHubGuardianActions} from "../common/interfaces/IGuardianActions.sol";
import {RequestCallbackMessageLib} from "../common/libraries/RequestCallbackMessageLib.sol";
import {IPoolEscrow, IPoolEscrowFactory} from "../common/factories/interfaces/IPoolEscrowFactory.sol";

/// @title  Hub
/// @notice Central pool management contract, that brings together all functions in one place.
///         Pools can assign hub managers which have full rights over all actions.
///
///         Also acts as the central contract that routes messages from other chains to the Hub contracts.
contract Hub is Multicall, Auth, Recoverable, IHub, IHubGatewayHandler, IHubGuardianActions {
    using MathLib for uint256;
    using RequestCallbackMessageLib for *;

    IGateway public gateway;
    IHoldings public holdings;
    IHubHelpers public hubHelpers;
    IAccounting public accounting;
    IHubRegistry public hubRegistry;
    IMultiAdapter public multiAdapter;
    IHubMessageSender public sender;
    IShareClassManager public shareClassManager;
    IPoolEscrowFactory public poolEscrowFactory;

    constructor(
        IGateway gateway_,
        IHoldings holdings_,
        IHubHelpers hubHelpers_,
        IAccounting accounting_,
        IHubRegistry hubRegistry_,
        IMultiAdapter multiAdapter_,
        IShareClassManager shareClassManager_,
        address deployer
    ) Auth(deployer) {
        gateway = gateway_;
        holdings = holdings_;
        hubHelpers = hubHelpers_;
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

        if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "shareClassManager") shareClassManager = IShareClassManager(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolEscrowFactory") poolEscrowFactory = IPoolEscrowFactory(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all messages sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatching();
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.endBatching();
        }
    }

    /// @inheritdoc IHubGuardianActions
    function createPool(PoolId poolId, address admin, AssetId currency) external {
        _auth();

        require(poolId.centrifugeId() == sender.localCentrifugeId(), InvalidPoolId());
        hubRegistry.registerPool(poolId, admin, currency);

        IPoolEscrow escrow = poolEscrowFactory.newEscrow(poolId);
        gateway.setRefundAddress(poolId, escrow);
    }

    //----------------------------------------------------------------------------------------------
    // Permissionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        protected
        returns (uint256 cost)
    {
        (uint128 totalPayoutShareAmount, uint128 totalPaymentAssetAmount, uint128 cancelledAssetAmount) =
            hubHelpers.notifyDeposit(poolId, scId, assetId, investor, maxClaims);

        if (totalPaymentAssetAmount > 0 || cancelledAssetAmount > 0) {
            return sender.sendRequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledDepositRequest(
                    investor, totalPaymentAssetAmount, totalPayoutShareAmount, cancelledAssetAmount
                ).serialize(),
                0
            );
        }
    }

    /// @inheritdoc IHub
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        protected
        returns (uint256 cost)
    {
        (uint128 totalPayoutAssetAmount, uint128 totalPaymentShareAmount, uint128 cancelledShareAmount) =
            hubHelpers.notifyRedeem(poolId, scId, assetId, investor, maxClaims);

        if (totalPaymentShareAmount > 0 || cancelledShareAmount > 0) {
            return sender.sendRequestCallback(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.FulfilledRedeemRequest(
                    investor, totalPayoutAssetAmount, totalPaymentShareAmount, cancelledShareAmount
                ).serialize(),
                0
            );
        }
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyPool(PoolId poolId, uint16 centrifugeId) external returns (uint256 cost) {
        _isManager(poolId);

        emit NotifyPool(centrifugeId, poolId);
        return sender.sendNotifyPool(centrifugeId, poolId);
    }

    /// @inheritdoc IHub
    function notifyShareClass(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook)
        external
        returns (uint256 cost)
    {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol, bytes32 salt) = shareClassManager.metadata(scId);
        uint8 decimals = hubRegistry.decimals(poolId);

        emit NotifyShareClass(centrifugeId, poolId, scId);
        return sender.sendNotifyShareClass(centrifugeId, poolId, scId, name, symbol, decimals, salt, hook);
    }

    /// @inheritdoc IHub
    function notifyShareMetadata(PoolId poolId, ShareClassId scId, uint16 centrifugeId) public returns (uint256 cost) {
        _isManager(poolId);

        (string memory name, string memory symbol,) = shareClassManager.metadata(scId);

        emit NotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
        return sender.sendNotifyShareMetadata(centrifugeId, poolId, scId, name, symbol);
    }

    /// @inheritdoc IHub
    function updateShareHook(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bytes32 hook)
        public
        returns (uint256 cost)
    {
        _isManager(poolId);

        emit UpdateShareHook(centrifugeId, poolId, scId, hook);
        return sender.sendUpdateShareHook(centrifugeId, poolId, scId, hook);
    }

    /// @inheritdoc IHub
    function notifySharePrice(PoolId poolId, ShareClassId scId, uint16 centrifugeId) public returns (uint256 cost) {
        _isManager(poolId);

        (, D18 poolPerShare) = shareClassManager.metrics(scId);

        emit NotifySharePrice(centrifugeId, poolId, scId, poolPerShare);
        return sender.sendNotifyPricePoolPerShare(centrifugeId, poolId, scId, poolPerShare);
    }

    /// @inheritdoc IHub
    function notifyAssetPrice(PoolId poolId, ShareClassId scId, AssetId assetId) public returns (uint256 cost) {
        _isManager(poolId);
        D18 pricePoolPerAsset = hubHelpers.pricePoolPerAsset(poolId, scId, assetId);
        emit NotifyAssetPrice(assetId.centrifugeId(), poolId, scId, assetId, pricePoolPerAsset);
        return sender.sendNotifyPricePoolPerAsset(poolId, scId, assetId, pricePoolPerAsset);
    }

    /// @inheritdoc IHub
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge)
        external
        returns (uint256 cost)
    {
        _isManager(poolId);

        emit SetMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
        return sender.sendMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
    }

    /// @inheritdoc IHub
    function setMaxSharePriceAge(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint64 maxPriceAge)
        external
        returns (uint256 cost)
    {
        _isManager(poolId);

        emit SetMaxSharePriceAge(centrifugeId, poolId, scId, maxPriceAge);
        return sender.sendMaxSharePriceAge(centrifugeId, poolId, scId, maxPriceAge);
    }

    /// @inheritdoc IHub
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external {
        _isManager(poolId);

        hubRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IHub
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external {
        _isManager(poolId);

        holdings.setSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHub
    function updateShareClassMetadata(PoolId poolId, ShareClassId scId, string calldata name, string calldata symbol)
        external
    {
        _isManager(poolId);

        shareClassManager.updateMetadata(poolId, scId, name, symbol);
    }

    /// @inheritdoc IHub
    function updateHubManager(PoolId poolId, address who, bool canManage) external {
        _isManager(poolId);

        hubRegistry.updateManager(poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function setRequestManager(PoolId poolId, uint16 centrifugeId, address hubManager, bytes32 spokeManager)
        external
        returns (uint256 cost)
    {
        _isManager(poolId);

        hubRegistry.setHubRequestManager(poolId, centrifugeId, hubManager);
        return sender.sendSetRequestManager(centrifugeId, poolId, spokeManager);
    }

    /// @inheritdoc IHub
    function updateBalanceSheetManager(uint16 centrifugeId, PoolId poolId, bytes32 who, bool canManage)
        external
        returns (uint256 cost)
    {
        _isManager(poolId);

        return sender.sendUpdateBalanceSheetManager(centrifugeId, poolId, who, canManage);
    }

    /// @inheritdoc IHub
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt)
        external
        returns (ShareClassId scId)
    {
        _isManager(poolId);

        return shareClassManager.addShareClass(poolId, name, symbol, salt);
    }

    /// @inheritdoc IHub
    function callRequestManager(PoolId poolId, uint16 centrifugeId, bytes calldata data)
        external
        returns (uint256 cost)
    {
        _isManager(poolId);
        (bool success, bytes memory returnData) = hubRegistry.hubRequestManager(poolId, centrifugeId).call(data);
        require(success, RequestManagerCallFailed());
        if (returnData.length >= 32) {
            return abi.decode(returnData, (uint256));
        }
        return 0;
    }

    /// @inheritdoc IHub
    function updateRestriction(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external returns (uint256 cost) {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateRestriction(centrifugeId, poolId, scId, payload);
        return sender.sendUpdateRestriction(centrifugeId, poolId, scId, payload, extraGasLimit);
    }

    /// @inheritdoc IHub
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        uint128 extraGasLimit
    ) external returns (uint256 cost) {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateVault(poolId, scId, assetId, vaultOrFactory, kind);
        return sender.sendUpdateVault(poolId, scId, assetId, vaultOrFactory, kind, extraGasLimit);
    }

    /// @inheritdoc IHub
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        uint16 centrifugeId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external returns (uint256 cost) {
        _isManager(poolId);

        require(shareClassManager.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        emit UpdateContract(centrifugeId, poolId, scId, target, payload);
        return sender.sendUpdateContract(centrifugeId, poolId, scId, target, payload, extraGasLimit);
    }

    /// @inheritdoc IHub
    function updateSharePrice(PoolId poolId, ShareClassId scId, D18 navPoolPerShare) public {
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
    ) external {
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
    ) external {
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
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) public {
        _isManager(poolId);

        (bool isPositive, uint128 diff) = holdings.update(poolId, scId, assetId);
        hubHelpers.updateAccountingValue(poolId, scId, assetId, isPositive, diff);
    }

    /// @inheritdoc IHub
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation) external {
        _isManager(poolId);

        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IHub
    function updateHoldingIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability) external {
        _isManager(poolId);

        holdings.updateIsLiability(poolId, scId, assetId, isLiability);
    }

    /// @inheritdoc IHub
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
    {
        _isManager(poolId);

        require(accounting.exists(poolId, accountId), IAccounting.AccountDoesNotExist());

        holdings.setAccountId(poolId, scId, assetId, kind, accountId);
    }

    /// @inheritdoc IHub
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) public {
        _isManager(poolId);

        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IHub
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external {
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

    /// @inheritdoc IHub
    function setAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        IAdapter[] memory localAdapters,
        bytes32[] memory remoteAdapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external returns (uint256 cost) {
        _isManager(poolId);

        multiAdapter.setAdapters(centrifugeId, poolId, localAdapters, threshold, recoveryIndex);

        return sender.sendSetPoolAdapters(centrifugeId, poolId, remoteAdapters, threshold, recoveryIndex);
    }

    /// @inheritdoc IHub
    function setGatewayManager(uint16 centrifugeId, PoolId poolId, bytes32 manager) external returns (uint256 cost) {
        _isManager(poolId);

        return sender.sendSetGatewayManager(centrifugeId, poolId, manager);
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
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external {
        _auth();

        address manager = hubRegistry.hubRequestManager(poolId, assetId.centrifugeId());
        require(address(manager) != address(0), InvalidRequestManager());

        IHubRequestManager(manager).request(poolId, scId, assetId, payload);
    }

    /// @inheritdoc IHubGatewayHandler
    function requestCallback(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external returns (uint256 cost) {
        address manager = hubRegistry.hubRequestManager(poolId, assetId.centrifugeId());
        require(manager != address(0), InvalidRequestManager());
        require(msg.sender == manager, NotAuthorized());

        return sender.sendRequestCallback(poolId, scId, assetId, payload, extraGasLimit);
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
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit
    ) external {
        _auth();

        emit ForwardTransferShares(targetCentrifugeId, poolId, scId, receiver, amount);
        sender.sendExecuteTransferShares(
            originCentrifugeId, targetCentrifugeId, poolId, scId, receiver, amount, extraGasLimit
        );
    }

    //----------------------------------------------------------------------------------------------
    //  Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Ensure the sender is authorized
    function _auth() internal auth {}

    /// @dev Ensure the sender is a pool admin
    function _isManager(PoolId poolId) internal {
        require(hubRegistry.manager(poolId, msg.sender), IHub.NotManager());
    }
}

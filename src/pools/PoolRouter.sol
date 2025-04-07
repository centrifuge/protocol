// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {MessageLib, UpdateContractType, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {IPoolRouterGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId, newAccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";

import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {IMultiShareClass} from "src/pools/interfaces/IMultiShareClass.sol";
import {IHoldings, Holding} from "src/pools/interfaces/IHoldings.sol";
import {IPoolRouter, EscrowId, AccountType} from "src/pools/interfaces/IPoolRouter.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";

// @inheritdoc IPoolRouter
contract PoolRouter is Auth, Multicall, IPoolRouter, IPoolRouterGatewayHandler {
    using MessageLib for *;
    using MathLib for uint256;
    using CastLib for bytes;
    using CastLib for bytes32;
    using CastLib for address;

    /// @dev Represents the unlocked pool Id in the multicall
    PoolId public transient unlockedPoolId;

    IPoolRegistry public poolRegistry;
    IAssetRegistry public assetRegistry;
    IAccounting public accounting;
    IHoldings public holdings;
    IPoolMessageSender public sender;
    IGateway public gateway;
    ITransientValuation immutable transientValuation;

    constructor(
        IPoolRegistry poolRegistry_,
        IAssetRegistry assetRegistry_,
        IAccounting accounting_,
        IHoldings holdings_,
        IGateway gateway_,
        ITransientValuation transientValuation_,
        address deployer
    ) Auth(deployer) {
        poolRegistry = poolRegistry_;
        assetRegistry = assetRegistry_;
        accounting = accounting_;
        holdings = holdings_;
        gateway = gateway_;
        transientValuation = transientValuation_;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRouter
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IPoolMessageSender(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "poolRegistry") poolRegistry = IPoolRegistry(data);
        else if (what == "assetRegistry") assetRegistry = IAssetRegistry(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "accounting") accounting = IAccounting(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all messages sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatching();
            gateway.topUp{value: msg.value}();
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.endBatching();
        }
    }

    /// @inheritdoc IPoolRouter
    function execute(PoolId poolId, bytes[] calldata data) external payable {
        require(unlockedPoolId.isNull(), IPoolRouter.PoolAlreadyUnlocked());
        require(poolRegistry.isAdmin(poolId, msg.sender), IPoolRouter.NotAuthorizedAdmin());

        accounting.unlock(poolId);
        unlockedPoolId = poolId;

        multicall(data);

        accounting.lock();
        unlockedPoolId = PoolId.wrap(0);
    }

    //----------------------------------------------------------------------------------------------
    // Permisionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRouter
    function createPool(address admin, AssetId currency, IShareClassManager shareClassManager_)
        external
        payable
        auth
        returns (PoolId poolId)
    {
        poolId = poolRegistry.registerPool(admin, sender.localCentrifugeId(), currency);
        poolRegistry.updateDependency(poolId, bytes32("shareClassManager"), address(shareClassManager_));
    }

    /// @inheritdoc IPoolRouter
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable {
        _protected();
        _pay();

        IShareClassManager scm = shareClassManager(poolId);

        (uint128 shares, uint128 tokens, uint128 cancelledAssetAmount) = scm.claimDeposit(poolId, scId, investor, assetId);
        sender.sendFulfilledDepositRequest(poolId, scId, assetId, investor, tokens, shares);

        // If cancellation was queued, notify about delayed cancellation
        if (cancelledAssetAmount > 0) {
            _cancelDepositRequest(poolId, scId, investor, assetId, cancelledAssetAmount);
        }
    }

    /// @inheritdoc IPoolRouter
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable {
        _protected();
        _pay();

        IShareClassManager scm = shareClassManager(poolId);

        (uint128 tokens, uint128 shares, uint128 cancelledShareAmount) = scm.claimRedeem(poolId, scId, investor, assetId);

        assetRegistry.burn(escrow(poolId, scId, EscrowId.PendingShareClass), assetId.raw(), tokens);

        sender.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, tokens, shares);

        // If cancellation was queued, notify about delayed cancellation
        if (cancelledShareAmount > 0) {
            sender.sendFulfilledCancelRedeemRequest(poolId, scId, assetId, investor, cancelledShareAmount);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRouter
    function notifyPool(uint16 chainId) external payable {
        _protectedAndUnlocked();

        sender.sendNotifyPool(chainId, unlockedPoolId);
    }

    /// @inheritdoc IPoolRouter
    function notifyShareClass(uint16 chainId, ShareClassId scId, bytes32 hook) external payable {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);
        require(scm.exists(unlockedPoolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol, bytes32 salt) = IMultiShareClass(address(scm)).metadata(scId);
        uint8 decimals = assetRegistry.decimals(poolRegistry.currency(unlockedPoolId).raw());

        sender.sendNotifyShareClass(chainId, unlockedPoolId, scId, name, symbol, decimals, salt, hook);
    }

    /// @inheritdoc IPoolRouter
    function setPoolMetadata(bytes calldata metadata) external payable {
        _protectedAndUnlocked();

        poolRegistry.setMetadata(unlockedPoolId, metadata);
    }

    /// @inheritdoc IPoolRouter
    function allowPoolAdmin(address account, bool allow) external payable {
        _protectedAndUnlocked();

        poolRegistry.updateAdmin(unlockedPoolId, account, allow);
    }

    /// @inheritdoc IPoolRouter
    function addShareClass(string calldata name, string calldata symbol, bytes32 salt, bytes calldata data)
        external
        payable
    {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);
        scm.addShareClass(unlockedPoolId, name, symbol, salt, data);
    }

    /// @inheritdoc IPoolRouter
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation)
        external
        payable
    {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);

        (uint128 approvedAssetAmount,) =
            scm.approveDeposits(unlockedPoolId, scId, maxApproval, paymentAssetId, valuation);

        assetRegistry.authTransferFrom(
            escrow(unlockedPoolId, scId, EscrowId.PendingShareClass),
            escrow(unlockedPoolId, scId, EscrowId.ShareClass),
            uint256(uint160(AssetId.unwrap(paymentAssetId))),
            approvedAssetAmount
        );

        uint128 valueChange = holdings.increase(unlockedPoolId, scId, paymentAssetId, valuation, approvedAssetAmount);

        accounting.addCredit(
            holdings.accountId(unlockedPoolId, scId, paymentAssetId, uint8(AccountType.Equity)), valueChange
        );
        accounting.addDebit(
            holdings.accountId(unlockedPoolId, scId, paymentAssetId, uint8(AccountType.Asset)), valueChange
        );
    }

    /// @inheritdoc IPoolRouter
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) external payable {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);

        scm.approveRedeems(unlockedPoolId, scId, maxApproval, payoutAssetId);
    }

    /// @inheritdoc IPoolRouter
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external payable {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);

        scm.issueShares(unlockedPoolId, scId, depositAssetId, navPerShare);
    }

    /// @inheritdoc IPoolRouter
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        payable
    {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);

        (uint128 payoutAssetAmount,) = scm.revokeShares(unlockedPoolId, scId, payoutAssetId, navPerShare, valuation);

        assetRegistry.authTransferFrom(
            escrow(unlockedPoolId, scId, EscrowId.ShareClass),
            escrow(unlockedPoolId, scId, EscrowId.PendingShareClass),
            uint256(uint160(AssetId.unwrap(payoutAssetId))),
            payoutAssetAmount
        );

        uint128 valueChange = holdings.decrease(unlockedPoolId, scId, payoutAssetId, valuation, payoutAssetAmount);

        accounting.addCredit(
            holdings.accountId(unlockedPoolId, scId, payoutAssetId, uint8(AccountType.Asset)), valueChange
        );
        accounting.addDebit(
            holdings.accountId(unlockedPoolId, scId, payoutAssetId, uint8(AccountType.Equity)), valueChange
        );
    }

    /// @inheritdoc IPoolRouter
    function updateRestriction(uint16 chainId, ShareClassId scId, bytes calldata payload)
        external
        payable
    {
        _protectedAndUnlocked();

        IShareClassManager scm = shareClassManager(unlockedPoolId);
        require(scm.exists(unlockedPoolId, scId), IShareClassManager.ShareClassNotFound());
        
        sender.sendUpdateRestriction(chainId, unlockedPoolId, scId, payload);
    }

    /// @inheritdoc IPoolRouter
    function updateContract(uint16 chainId, ShareClassId scId, bytes32 target, bytes calldata payload)
        external
        payable
    {
        _protectedAndUnlocked();

        sender.sendUpdateContract(chainId, unlockedPoolId, scId, target, payload);
    }

    /// @inheritdoc IPoolRouter
    function updateVault(
        ShareClassId scId,
        AssetId assetId,
        bytes32 target,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind
    ) public payable {
        _protectedAndUnlocked();

        sender.sendUpdateContract(
            assetId.chainId(),
            unlockedPoolId,
            scId,
            target,
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: vaultOrFactory,
                assetId: assetId.raw(),
                kind: uint8(kind)
            }).serialize()
        );
    }

    /// @inheritdoc IPoolRouter
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, bool isLiability, uint24 prefix)
        external
        payable
    {
        _protectedAndUnlocked();

        require(assetRegistry.isRegistered(assetId), IAssetRegistry.AssetNotFound());

        AccountId[] memory accounts = new AccountId[](6);
        accounts[0] = newAccountId(prefix, uint8(AccountType.Asset));
        accounts[1] = newAccountId(prefix, uint8(AccountType.Equity));
        accounts[2] = newAccountId(prefix, uint8(AccountType.Loss));
        accounts[3] = newAccountId(prefix, uint8(AccountType.Gain));
        accounts[4] = newAccountId(prefix, uint8(AccountType.Expense));
        accounts[5] = newAccountId(prefix, uint8(AccountType.Liability));

        createAccount(accounts[0], true);
        createAccount(accounts[1], false);
        createAccount(accounts[2], false);
        createAccount(accounts[3], false);
        createAccount(accounts[4], true);
        createAccount(accounts[5], false);

        holdings.create(unlockedPoolId, scId, assetId, valuation, isLiability, accounts);
    }

    /// @inheritdoc IPoolRouter
    function updateHolding(ShareClassId scId, AssetId assetId) public payable {
        _protectedAndUnlocked();

        int128 diff = holdings.update(unlockedPoolId, scId, assetId);

        if (diff > 0) {
            if (holdings.isLiability(unlockedPoolId, scId, assetId)) {
                accounting.addCredit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Liability)), uint128(diff)
                );
                accounting.addDebit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Expense)), uint128(diff)
                );
            } else {
                accounting.addCredit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Gain)), uint128(diff)
                );
                accounting.addDebit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Asset)), uint128(diff)
                );
            }
        } else if (diff < 0) {
            if (holdings.isLiability(unlockedPoolId, scId, assetId)) {
                accounting.addCredit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Expense)), uint128(diff)
                );
                accounting.addDebit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Liability)), uint128(diff)
                );
            } else {
                accounting.addCredit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Asset)), uint128(diff)
                );
                accounting.addDebit(
                    holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.Loss)), uint128(diff)
                );
            }
        }
    }

    /// @inheritdoc IPoolRouter
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external payable {
        _protectedAndUnlocked();

        holdings.updateValuation(unlockedPoolId, scId, assetId, valuation);
    }

    /// @inheritdoc IPoolRouter
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external payable {
        _protectedAndUnlocked();

        holdings.setAccountId(unlockedPoolId, scId, assetId, accountId);
    }

    /// @inheritdoc IPoolRouter
    function createAccount(AccountId account, bool isDebitNormal) public payable {
        _protectedAndUnlocked();

        accounting.createAccount(unlockedPoolId, account, isDebitNormal);
    }

    /// @inheritdoc IPoolRouter
    function setAccountMetadata(AccountId account, bytes calldata metadata) external payable {
        _protectedAndUnlocked();

        accounting.setAccountMetadata(unlockedPoolId, account, metadata);
    }

    /// @inheritdoc IPoolRouter
    function addDebit(AccountId account, uint128 amount) external payable {
        _protectedAndUnlocked();

        accounting.addDebit(account, amount);
    }

    /// @inheritdoc IPoolRouter
    function addCredit(AccountId account, uint128 amount) external payable {
        _protectedAndUnlocked();

        accounting.addCredit(account, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRouterGatewayHandler
    function registerAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals)
        external
        auth
    {
        assetRegistry.registerAsset(assetId, name, symbol, decimals);
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount)
        external
        auth
    {
        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PendingShareClass);
        assetRegistry.mint(pendingShareClassEscrow, depositAssetId.raw(), amount);

        IShareClassManager scm = shareClassManager(poolId);
        scm.requestDeposit(poolId, scId, amount, investor, depositAssetId);
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount)
        external
        auth
    {
        IShareClassManager scm = shareClassManager(poolId);
        scm.requestRedeem(poolId, scId, amount, investor, payoutAssetId);
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        auth
    {
        IShareClassManager scm = shareClassManager(poolId);
        uint128 cancelledAssetAmount = scm.cancelDepositRequest(poolId, scId, investor, depositAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledAssetAmount > 0) {
            _cancelDepositRequest(poolId, scId, investor, depositAssetId, cancelledAssetAmount);
        }
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        auth
    {
        IShareClassManager scm = shareClassManager(poolId);
        uint128 cancelledShareAmount = scm.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        // Cancellation might have been queued such that it will be executed in the future during claiming
        if (cancelledShareAmount > 0) {
            sender.sendFulfilledCancelRedeemRequest(poolId, scId, payoutAssetId, investor, cancelledShareAmount);
        }
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function updateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePerUnit,
        bool isIncrease,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external auth {
        accounting.unlock(poolId);
        address poolCurrency = poolRegistry.currency(poolId).addr();
        transientValuation.setPrice(assetId.addr(), poolCurrency, pricePerUnit);
        uint128 valueChange = transientValuation.getQuote(amount, assetId.addr(), poolCurrency).toUint128();

        (uint128 debited, uint128 credited) = _updateJournal(debits, credits);
        uint128 debitValueLeft = valueChange - debited;
        uint128 creditValueLeft = valueChange - credited;

        _updateHoldingWithPartialDebitsAndCredits(
            poolId, scId, assetId, amount, isIncrease, debitValueLeft, creditValueLeft
        );
        accounting.lock();
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePerUnit) external auth {
        transientValuation.setPrice(assetId.addr(), poolRegistry.currency(poolId).addr(), pricePerUnit);
        IERC7726 _valuation = holdings.valuation(poolId, scId, assetId);
        holdings.updateValuation(poolId, scId, assetId, transientValuation);

        accounting.unlock(poolId);
        updateHolding(scId, assetId);
        accounting.lock();

        holdings.updateValuation(poolId, scId, assetId, _valuation);
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function updateJournal(PoolId poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) external auth {
        accounting.unlock(poolId);
        _updateJournal(debits, credits);
        accounting.lock();
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function increaseShareIssuance(PoolId poolId, ShareClassId scId, D18 pricePerShare, uint128 amount) external auth {
        IShareClassManager scm = shareClassManager(poolId);
        scm.increaseShareClassIssuance(poolId, scId, pricePerShare, amount);
    }

    /// @inheritdoc IPoolRouterGatewayHandler
    function decreaseShareIssuance(PoolId poolId, ShareClassId scId, D18 pricePerShare, uint128 amount) external auth {
        IShareClassManager scm = shareClassManager(poolId);
        scm.decreaseShareClassIssuance(poolId, scId, pricePerShare, amount);
    }

    //----------------------------------------------------------------------------------------------
    // view / pure methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolRouter
    function escrow(PoolId poolId, ShareClassId scId, EscrowId escrow_) public pure returns (address) {
        return address(bytes20(keccak256(abi.encodePacked("escrow", poolId, scId, escrow_))));
    }

    /// @inheritdoc IPoolRouter
    function shareClassManager(PoolId poolId) public view returns (IShareClassManager) {
        return IShareClassManager(poolRegistry.dependency(poolId, bytes32("shareClassManager")));
    }

    /// @dev Ensure the method is protected (see `_protected()`) and the pool is unlocked,
    /// which mean the method must be called though `execute()`
    function _protectedAndUnlocked() internal protected {
        require(!unlockedPoolId.isNull(), IPoolRouter.PoolLocked());
    }

    /// @dev Ensure the method can be used without reentrancy issues
    function _protected() internal protected {}

    /// @notice Send native tokens to the gateway for transaction payment if it's not in a multicall.
    function _pay() internal {
        if (!gateway.isBatching()) {
            gateway.topUp{value: msg.value}();
        }
    }

    /// @notice Update the journal with the given debits and credits. Can be unequal.
    function _updateJournal(JournalEntry[] memory debits, JournalEntry[] memory credits)
        internal
        returns (uint128 debited, uint128 credited)
    {
        for (uint256 i; i < debits.length; i++) {
            accounting.addDebit(debits[i].accountId, debits[i].amount);
            debited += debits[i].amount;
        }

        for (uint256 i; i < credits.length; i++) {
            accounting.addCredit(credits[i].accountId, credits[i].amount);
            credited += credits[i].amount;
        }
    }

    /// @notice Update a holding while debiting and/or crediting only a portion of the value change.
    function _updateHoldingWithPartialDebitsAndCredits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        bool isIncrease,
        uint128 debitValue,
        uint128 creditValue
    ) internal {
        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType debitAccountType = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType creditAccountType = isLiability ? AccountType.Liability : AccountType.Equity;

        if (isIncrease) {
            holdings.increase(poolId, scId, assetId, transientValuation, amount);
            accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(debitAccountType)), debitValue);
            accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(creditAccountType)), creditValue);
        } else {
            holdings.decrease(poolId, scId, assetId, transientValuation, amount);
            accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(creditAccountType)), debitValue);
            accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(debitAccountType)), creditValue);
        }
    }

    /// @notice Burn the asset amount in the pending share class escrow and send a fulfilled cancel deposit request.
    function _cancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId,
        uint128 cancelledAssetAmount
    ) internal {
        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PendingShareClass);
        assetRegistry.burn(pendingShareClassEscrow, depositAssetId.raw(), cancelledAssetAmount);

        sender.sendFulfilledCancelDepositRequest(poolId, scId, depositAssetId, investor, cancelledAssetAmount);
    }
}

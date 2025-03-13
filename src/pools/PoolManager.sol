// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall} from "src/misc/Multicall.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId, newAccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {IMultiShareClass} from "src/pools/interfaces/IMultiShareClass.sol";
import {IHoldings} from "src/pools/interfaces/IHoldings.sol";
import {IMessageProcessor} from "src/pools/interfaces/IMessageProcessor.sol";
import {IPoolManager, IPoolManagerHandler, EscrowId, AccountType} from "src/pools/interfaces/IPoolManager.sol";

// @inheritdoc IPoolManager
contract PoolManager is Auth, IPoolManager, IPoolManagerHandler {
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
    IGateway public gateway;
    IMessageProcessor public sender;

    /// @dev A requirement for methods that needs to be called through `execute()`
    modifier poolUnlocked() {
        require(!unlockedPoolId.isNull(), IPoolManager.PoolLocked());
        _;
    }

    constructor(
        IPoolRegistry poolRegistry_,
        IAssetRegistry assetRegistry_,
        IAccounting accounting_,
        IHoldings holdings_,
        IGateway gateway_,
        address deployer
    ) Auth(deployer) {
        poolRegistry = poolRegistry_;
        assetRegistry = assetRegistry_;
        accounting = accounting_;
        gateway = gateway_;
        holdings = holdings_;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IMessageProcessor(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "poolRegistry") poolRegistry = IPoolRegistry(data);
        else if (what == "assetRegistry") assetRegistry = IAssetRegistry(data);
        else if (what == "accounting") accounting = IAccounting(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @inheritdoc IPoolManager
    function unlock(PoolId poolId, address admin) external auth {
        require(unlockedPoolId.isNull(), IPoolManager.PoolAlreadyUnlocked());
        require(poolRegistry.isAdmin(poolId, admin), IPoolManager.NotAuthorizedAdmin());

        gateway.setPayableSource(admin);
        gateway.startBatch();

        accounting.unlock(poolId, "TODO");
        unlockedPoolId = poolId;
    }

    /// @inheritdoc IPoolManager
    function lock() external payable auth {
        accounting.lock();
        unlockedPoolId = PoolId.wrap(0);

        gateway.topUp{value: msg.value}();
        gateway.endBatch();
    }

    //----------------------------------------------------------------------------------------------
    // Permisionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function createPool(address admin, AssetId currency, IShareClassManager shareClassManager)
        external
        returns (PoolId poolId)
    {
        // TODO: add fees
        return poolRegistry.registerPool(admin, currency, shareClassManager);
    }

    /// @inheritdoc IPoolManager
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimDeposit(poolId, scId, investor, assetId);
        sender.sendFulfilledDepositRequest(poolId, scId, assetId, investor, tokens, shares);
    }

    /// @inheritdoc IPoolManager
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 tokens, uint128 shares) = scm.claimRedeem(poolId, scId, investor, assetId);

        assetRegistry.burn(escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS), assetId.raw(), tokens);

        sender.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, tokens, shares);
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function notifyPool(uint32 chainId) external auth poolUnlocked {
        sender.sendNotifyPool(chainId, unlockedPoolId);
    }

    /// @inheritdoc IPoolManager
    function notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) external auth poolUnlocked {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);
        require(scm.exists(unlockedPoolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol, bytes32 salt) = IMultiShareClass(address(scm)).metadata(scId);
        uint8 decimals = assetRegistry.decimals(poolRegistry.currency(unlockedPoolId).raw());

        sender.sendNotifyShareClass(chainId, unlockedPoolId, scId, name, symbol, decimals, salt, hook);
    }

    /// @inheritdoc IPoolManager
    function setPoolMetadata(bytes calldata metadata) external auth poolUnlocked {
        poolRegistry.setMetadata(unlockedPoolId, metadata);
    }

    /// @inheritdoc IPoolManager
    function allowPoolAdmin(address account, bool allow) external auth poolUnlocked {
        poolRegistry.updateAdmin(unlockedPoolId, account, allow);
    }

    /// @inheritdoc IPoolManager
    function allowAsset(ShareClassId scId, AssetId assetId, bool /*allow*/ ) external view auth poolUnlocked {
        require(holdings.exists(unlockedPoolId, scId, assetId), IHoldings.HoldingNotFound());

        // TODO: cal update contract feature
    }

    /// @inheritdoc IPoolManager
    function addShareClass(string calldata name, string calldata symbol, bytes32 salt, bytes calldata data)
        external
        auth
        poolUnlocked
    {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);
        scm.addShareClass(unlockedPoolId, name, symbol, salt, data);
    }

    /// @inheritdoc IPoolManager
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation)
        external
        auth
        poolUnlocked
    {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        (uint128 approvedAssetAmount, ) = scm.approveDeposits(unlockedPoolId, scId, maxApproval, paymentAssetId, valuation);

        assetRegistry.authTransferFrom(
            escrow(unlockedPoolId, scId, EscrowId.PENDING_SHARE_CLASS),
            escrow(unlockedPoolId, scId, EscrowId.SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(paymentAssetId))),
            approvedAssetAmount
        );

        increaseHolding(scId, paymentAssetId, valuation, approvedAssetAmount);
    }

    /// @inheritdoc IPoolManager
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) external auth poolUnlocked {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        scm.approveRedeems(unlockedPoolId, scId, maxApproval, payoutAssetId);
    }

    /// @inheritdoc IPoolManager
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external auth poolUnlocked {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        scm.issueShares(unlockedPoolId, scId, depositAssetId, navPerShare);
    }

    /// @inheritdoc IPoolManager
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        auth
        poolUnlocked
    {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        (uint128 payoutAssetAmount,) = scm.revokeShares(unlockedPoolId, scId, payoutAssetId, navPerShare, valuation);

        assetRegistry.authTransferFrom(
            escrow(unlockedPoolId, scId, EscrowId.SHARE_CLASS),
            escrow(unlockedPoolId, scId, EscrowId.PENDING_SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(payoutAssetId))),
            payoutAssetAmount
        );

        decreaseHolding(scId, payoutAssetId, valuation, payoutAssetAmount);
    }

    /// @inheritdoc IPoolManager
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix)
        external
        auth
        poolUnlocked
    {
        require(assetRegistry.isRegistered(assetId), IAssetRegistry.AssetNotFound());

        AccountId[] memory accounts = new AccountId[](4);
        accounts[0] = newAccountId(prefix, uint8(AccountType.ASSET));
        accounts[1] = newAccountId(prefix, uint8(AccountType.EQUITY));
        accounts[2] = newAccountId(prefix, uint8(AccountType.LOSS));
        accounts[3] = newAccountId(prefix, uint8(AccountType.GAIN));

        createAccount(accounts[0], true);
        createAccount(accounts[1], false);
        createAccount(accounts[2], false);
        createAccount(accounts[3], false);

        holdings.create(unlockedPoolId, scId, assetId, valuation, accounts);
    }

    /// @inheritdoc IPoolManager
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        auth
        poolUnlocked
    {
        uint128 valueChange = holdings.increase(unlockedPoolId, scId, assetId, valuation, amount);

        accounting.addCredit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.EQUITY)), valueChange);
        accounting.addDebit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.ASSET)), valueChange);
    }

    /// @inheritdoc IPoolManager
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        auth
        poolUnlocked
    {
        uint128 valueChange = holdings.decrease(unlockedPoolId, scId, assetId, valuation, amount);

        accounting.addCredit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.ASSET)), valueChange);
        accounting.addDebit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.EQUITY)), valueChange);
    }

    /// @inheritdoc IPoolManager
    function updateHolding(ShareClassId scId, AssetId assetId) external auth poolUnlocked {
        int128 diff = holdings.update(unlockedPoolId, scId, assetId);

        if (diff > 0) {
            accounting.addCredit(
                holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.GAIN)), uint128(diff)
            );
            accounting.addDebit(
                holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.ASSET)), uint128(diff)
            );
        } else if (diff < 0) {
            accounting.addCredit(
                holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.ASSET)), uint128(diff)
            );
            accounting.addDebit(
                holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.LOSS)), uint128(diff)
            );
        }
    }

    /// @inheritdoc IPoolManager
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external auth poolUnlocked {
        holdings.updateValuation(unlockedPoolId, scId, assetId, valuation);
    }

    /// @inheritdoc IPoolManager
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external auth poolUnlocked {
        holdings.setAccountId(unlockedPoolId, scId, assetId, accountId);
    }

    /// @inheritdoc IPoolManager
    function createAccount(AccountId account, bool isDebitNormal) public auth poolUnlocked {
        accounting.createAccount(unlockedPoolId, account, isDebitNormal);
    }

    /// @inheritdoc IPoolManager
    function setAccountMetadata(AccountId account, bytes calldata metadata) external auth poolUnlocked {
        accounting.setAccountMetadata(unlockedPoolId, account, metadata);
    }

    /// @inheritdoc IPoolManager
    function addDebit(AccountId account, uint128 amount) external auth poolUnlocked {
        accounting.addDebit(account, amount);
    }

    /// @inheritdoc IPoolManager
    function addCredit(AccountId account, uint128 amount) external auth poolUnlocked {
        accounting.addCredit(account, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManagerHandler
    function registerAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals)
        external
        auth
    {
        assetRegistry.registerAsset(assetId, name, symbol, decimals);
    }

    /// @inheritdoc IPoolManagerHandler
    function depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount)
        external
        auth
    {
        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetRegistry.mint(pendingShareClassEscrow, depositAssetId.raw(), amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId, amount, investor, depositAssetId);
    }

    /// @inheritdoc IPoolManagerHandler
    function redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount)
        external
        auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestRedeem(poolId, scId, amount, investor, payoutAssetId);
    }

    /// @inheritdoc IPoolManagerHandler
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 cancelledAssetAmount) = scm.cancelDepositRequest(poolId, scId, investor, depositAssetId);

        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetRegistry.burn(pendingShareClassEscrow, depositAssetId.raw(), cancelledAssetAmount);

        sender.sendFulfilledCancelDepositRequest(poolId, scId, depositAssetId, investor, cancelledAssetAmount);
    }

    /// @inheritdoc IPoolManagerHandler
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        uint128 cancelledShareAmount = scm.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        sender.sendFulfilledCancelRedeemRequest(poolId, scId, payoutAssetId, investor, cancelledShareAmount);
    }

    //----------------------------------------------------------------------------------------------
    // view / pure methods
    //----------------------------------------------------------------------------------------------

    function escrow(PoolId poolId, ShareClassId scId, EscrowId escrow_) public pure returns (address) {
        return address(bytes20(keccak256(abi.encodePacked("escrow", poolId, scId, escrow_))));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {D18} from "src/types/D18.sol";

import {IAccounting} from "src/interfaces/IAccounting.sol";
import {IGateway} from "src/interfaces/IGateway.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {
    IPoolManager,
    IPoolManagerAdminMethods,
    IPoolManagerHandlers,
    EscrowId,
    AccountType
} from "src/interfaces/IPoolManager.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {IERC7726, IERC7726Ext} from "src/interfaces/IERC7726.sol";

import {MathLib} from "src/libraries/MathLib.sol";
import {CastLib} from "src/libraries/CastLib.sol";

import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

// @inheritdoc IPoolManager
contract PoolManager is Auth, PoolLocker, IPoolManager, IPoolManagerHandlers {
    using MathLib for uint256;
    using CastLib for bytes;
    using CastLib for bytes32;
    using CastLib for address;

    IPoolRegistry public poolRegistry;
    IAssetManager public assetManager;
    IAccounting public accounting;
    IHoldings public holdings;
    IGateway public gateway;

    /// @dev A requirement for methods that needs to be called by the gateway
    modifier onlyGateway() {
        require(msg.sender == address(gateway), NotGateway());
        _;
    }

    constructor(
        IMulticall multicall,
        IPoolRegistry poolRegistry_,
        IAssetManager assetManager_,
        IAccounting accounting_,
        IHoldings holdings_,
        IGateway gateway_,
        address deployer
    ) Auth(deployer) PoolLocker(multicall) {
        poolRegistry = poolRegistry_;
        assetManager = assetManager_;
        accounting = accounting_;
        holdings = holdings_;
        gateway = gateway_;
    }

    //----------------------------------------------------------------------------------------------
    // Deployer methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "poolRegistry") poolRegistry = IPoolRegistry(data);
        else if (what == "assetManager") assetManager = IAssetManager(data);
        else if (what == "accounting") accounting = IAccounting(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Permisionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function createPool(AssetId currency, IShareClassManager shareClassManager) external returns (PoolId poolId) {
        // TODO: add fees
        return poolRegistry.registerPool(msg.sender, currency, shareClassManager);
    }

    /// @inheritdoc IPoolManager
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) =
            scm.claimDeposit(poolId, scId.toBytes(), assetId.addr(), address(uint160(uint256(investor))));
        gateway.sendFulfilledDepositRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    /// @inheritdoc IPoolManager
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) =
            scm.claimRedeem(poolId, scId.toBytes(), assetId.addr(), address(uint160(uint256(investor))));

        assetManager.burn(escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS), assetId.raw(), tokens);

        gateway.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManagerAdminMethods
    function notifyPool(uint32 chainId) external poolUnlocked {
        gateway.sendNotifyPool(chainId, unlockedPoolId());
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function notifyShareClass(uint32 chainId, ShareClassId scId) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        require(scm.exists(poolId, scId.toBytes()), IShareClassManager.ShareClassNotFound());

        gateway.sendNotifyShareClass(chainId, poolId, scId);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function notifyAllowedAsset(ShareClassId scId, AssetId assetId) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        gateway.sendNotifyAllowedAsset(poolId, scId, assetId, poolRegistry.isInvestorAssetAllowed(poolId, assetId));
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function setPoolMetadata(bytes calldata metadata) external {
        poolRegistry.setMetadata(unlockedPoolId(), metadata);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function allowPoolAdmin(address account, bool allow) external {
        poolRegistry.updateAdmin(unlockedPoolId(), account, allow);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function allowHoldingAsset(AssetId assetId, bool allow) external {
        PoolId poolId = unlockedPoolId();

        if (!allow) {
            require(!poolRegistry.isInvestorAssetAllowed(poolId, assetId), InvestorAssetStillAllowed());
        }

        holdings.allowAsset(poolId, assetId, allow);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function allowInvestorAsset(AssetId assetId, bool allow) external {
        PoolId poolId = unlockedPoolId();

        require(assetManager.isRegistered(assetId), IAssetManager.AssetNotFound());
        require(holdings.isAssetAllowed(poolId, assetId), IHoldings.AssetNotAllowed());

        poolRegistry.allowInvestorAsset(poolId, assetId, allow);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function addShareClass(bytes calldata data) external returns (ShareClassId) {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        return ShareClassId.wrap(scm.addShareClass(poolId, data));
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, D18 approvalRatio, IERC7726 valuation)
        external
        poolUnlocked
    {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (, uint128 approvedAssetAmount) = scm.approveDeposits(
            poolId, scId.toBytes(), approvalRatio, paymentAssetId.addr(), IERC7726Ext(address(valuation))
        );

        assetManager.authTransferFrom(
            escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS),
            escrow(poolId, scId, EscrowId.SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(paymentAssetId))),
            approvedAssetAmount
        );

        increaseHolding(scId, paymentAssetId, valuation, approvedAssetAmount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        IERC7726 valuation = holdings.valuation(poolId, scId, payoutAssetId);

        scm.approveRedeems(poolId, scId.toBytes(), approvalRatio, payoutAssetId.addr(), IERC7726Ext(address(valuation)));
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        scm.issueShares(poolId, scId.toBytes(), depositAssetId.addr(), navPerShare);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        poolUnlocked
    {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 payoutAssetAmount,) = scm.revokeShares(poolId, scId.toBytes(), payoutAssetId.addr(), navPerShare);

        assetManager.authTransferFrom(
            escrow(poolId, scId, EscrowId.SHARE_CLASS),
            escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(payoutAssetId))),
            payoutAssetAmount
        );

        decreaseHolding(scId, payoutAssetId, valuation, payoutAssetAmount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, AccountId[] memory accounts)
        external
        poolUnlocked
    {
        holdings.create(unlockedPoolId(), scId, assetId, valuation, accounts);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        poolUnlocked
    {
        PoolId poolId = unlockedPoolId();

        uint128 valueChange = holdings.increase(poolId, scId, assetId, valuation, amount);

        updateEntry(
            holdings.accountId(poolId, scId, assetId, uint8(AccountType.EQUITY)),
            holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)),
            valueChange
        );
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        poolUnlocked
    {
        PoolId poolId = unlockedPoolId();

        uint128 valueChange = holdings.decrease(poolId, scId, assetId, valuation, amount);

        updateEntry(
            holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)),
            holdings.accountId(poolId, scId, assetId, uint8(AccountType.EQUITY)),
            valueChange
        );
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function updateHolding(ShareClassId scId, AssetId assetId) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        int128 diff = holdings.update(poolId, scId, assetId);

        if (diff > 0) {
            updateEntry(
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.GAIN)),
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)),
                uint128(diff)
            );
        } else if (diff < 0) {
            updateEntry(
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)),
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.LOSS)),
                uint128(-diff)
            );
        }
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external poolUnlocked {
        holdings.updateValuation(unlockedPoolId(), scId, assetId, valuation);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external poolUnlocked {
        holdings.setAccountId(unlockedPoolId(), scId, assetId, accountId);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function createAccount(AccountId account, bool isDebitNormal) external poolUnlocked {
        accounting.createAccount(unlockedPoolId(), account, isDebitNormal);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function setAccountMetadata(AccountId account, bytes calldata metadata) external poolUnlocked {
        accounting.setAccountMetadata(unlockedPoolId(), account, metadata);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function updateEntry(AccountId credit, AccountId debit, uint128 amount) public poolUnlocked {
        accounting.addCredit(credit, amount);
        accounting.addDebit(debit, amount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function addDebit(AccountId account, uint128 amount) external poolUnlocked {
        accounting.addDebit(account, amount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function addCredit(AccountId account, uint128 amount) external poolUnlocked {
        accounting.addCredit(account, amount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function unlockAssets(ShareClassId scId, AssetId assetId, bytes32 receiver, uint128 assetAmount)
        external
        poolUnlocked
    {
        assetManager.burn(escrow(unlockedPoolId(), scId, EscrowId.SHARE_CLASS), assetId.raw(), assetAmount);

        gateway.sendUnlockAssets(assetId, receiver, assetAmount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManagerHandlers
    function handleRegisterAsset(AssetId assetId, bytes calldata name, bytes32 symbol, uint8 decimals)
        external
        onlyGateway
    {
        assetManager.registerAsset(assetId, name.bytes128ToString(), symbol.toString(), decimals);
    }

    /// @inheritdoc IPoolManagerHandlers
    function handleRequestDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        bytes32 investor,
        uint128 amount
    ) external onlyGateway {
        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetManager.mint(pendingShareClassEscrow, depositAssetId.raw(), amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId.toBytes(), amount, address(uint160(uint256(investor))), depositAssetId.addr());
    }

    /// @inheritdoc IPoolManagerHandlers
    function handleRequestRedeem(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        bytes32 investor,
        uint128 amount
    ) external onlyGateway {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestRedeem(poolId, scId.toBytes(), amount, address(uint160(uint256(investor))), payoutAssetId.addr());
    }

    /// @inheritdoc IPoolManagerHandlers
    function handleCancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId depositAssetId, bytes32 investor)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 cancelledAssetAmount) =
            scm.cancelDepositRequest(poolId, scId.toBytes(), address(uint160(uint256(investor))), depositAssetId.addr());

        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetManager.burn(pendingShareClassEscrow, depositAssetId.raw(), cancelledAssetAmount);

        gateway.sendFulfilledCancelDepositRequest(
            poolId, scId, depositAssetId, investor, cancelledAssetAmount, cancelledAssetAmount
        );
    }

    /// @inheritdoc IPoolManagerHandlers
    function handleCancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, bytes32 investor)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        uint128 cancelledAssetAmount =
            scm.cancelRedeemRequest(poolId, scId.toBytes(), address(uint160(uint256(investor))), payoutAssetId.addr());

        gateway.sendFulfilledRedeemRequest(
            poolId, scId, payoutAssetId, investor, cancelledAssetAmount, cancelledAssetAmount
        );
    }

    /// @inheritdoc IPoolManagerHandlers
    function handleLockedTokens(address receiver, AssetId assetId, uint128 amount) external onlyGateway {
        assetManager.mint(receiver, assetId.raw(), amount);
    }

    //----------------------------------------------------------------------------------------------
    // view / pure methods
    //----------------------------------------------------------------------------------------------

    function escrow(PoolId poolId, ShareClassId scId, EscrowId escrow_) public pure returns (address) {
        return address(bytes20(keccak256(abi.encodePacked("escrow", poolId, scId, escrow_))));
    }

    //----------------------------------------------------------------------------------------------
    // internal / private methods
    //----------------------------------------------------------------------------------------------

    function _beforeLock() internal override {
        accounting.lock();
    }

    function _beforeUnlock(PoolId poolId) internal override {
        require(poolRegistry.isAdmin(poolId, msg.sender));
        accounting.unlock(unlockedPoolId(), bytes32("TODO"));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall} from "src/misc/Multicall.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId, newAccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {IGateway} from "src/pools/interfaces/IGateway.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {ISingleShareClass} from "src/pools/interfaces/ISingleShareClass.sol";
import {IHoldings} from "src/pools/interfaces/IHoldings.sol";
import {
    IPoolManager,
    IPoolManagerAdminMethods,
    IPoolManagerHandler,
    EscrowId,
    AccountType
} from "src/pools/interfaces/IPoolManager.sol";

// @inheritdoc IPoolManager
contract PoolManager is Auth, Multicall, IPoolManager, IPoolManagerHandler {
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

    /// @dev A requirement for methods that needs to be called by the gateway
    modifier onlyGateway() {
        require(msg.sender == address(gateway), NotGateway());
        _;
    }

    /// @dev A requirement for methods that needs to be called through `execute()`
    modifier poolUnlocked() {
        require(!unlockedPoolId.isNull(), IPoolManagerAdminMethods.PoolLocked());
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
        else if (what == "assetRegistry") assetRegistry = IAssetRegistry(data);
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
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external protected {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimDeposit(poolId, scId, investor, assetId);
        gateway.sendFulfilledDepositRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    /// @inheritdoc IPoolManager
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external protected {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimRedeem(poolId, scId, investor, assetId);

        assetRegistry.burn(escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS), assetId.raw(), tokens);

        gateway.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------
    /// @inheritdoc IPoolManagerAdminMethods
    function execute(PoolId poolId, bytes[] calldata data) external payable {
        require(unlockedPoolId.isNull(), PoolAlreadyUnlocked());
        require(poolRegistry.isAdmin(poolId, msg.sender), NotAuthorizedAdmin());

        accounting.unlock(poolId, bytes32("TODO"));
        unlockedPoolId = poolId;

        multicall(data);

        accounting.lock();
        unlockedPoolId = PoolId.wrap(0);
    }

    function notifyPool(uint32 chainId) external poolUnlocked protected {
        gateway.sendNotifyPool(chainId, unlockedPoolId);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) external poolUnlocked {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);
        require(scm.exists(unlockedPoolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol) = ISingleShareClass(address(scm)).metadata(scId);
        uint8 decimals = assetRegistry.decimals(poolRegistry.currency(unlockedPoolId).raw());

        gateway.sendNotifyShareClass(chainId, unlockedPoolId, scId, name, symbol, decimals, hook);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function setPoolMetadata(bytes calldata metadata) external poolUnlocked protected {
        poolRegistry.setMetadata(unlockedPoolId, metadata);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function allowPoolAdmin(address account, bool allow) external poolUnlocked protected {
        poolRegistry.updateAdmin(unlockedPoolId, account, allow);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function allowInvestorAsset(ShareClassId scId, AssetId assetId, bool allow) external poolUnlocked protected {
        require(holdings.exists(unlockedPoolId, scId, assetId), IHoldings.HoldingNotFound());

        poolRegistry.allowInvestorAsset(unlockedPoolId, assetId, allow);

        gateway.sendNotifyAllowedAsset(
            unlockedPoolId, scId, assetId, poolRegistry.isInvestorAssetAllowed(unlockedPoolId, assetId)
        );
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function addShareClass(bytes calldata data) external poolUnlocked protected returns (ShareClassId) {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);
        return scm.addShareClass(unlockedPoolId, data);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, D18 approvalRatio, IERC7726 valuation)
        external
        poolUnlocked
        protected
    {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        (uint128 approvedAssetAmount,) =
            scm.approveDeposits(unlockedPoolId, scId, approvalRatio, paymentAssetId, valuation);

        assetRegistry.authTransferFrom(
            escrow(unlockedPoolId, scId, EscrowId.PENDING_SHARE_CLASS),
            escrow(unlockedPoolId, scId, EscrowId.SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(paymentAssetId))),
            approvedAssetAmount
        );

        increaseHolding(scId, paymentAssetId, valuation, approvedAssetAmount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio)
        external
        poolUnlocked
        protected
    {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        scm.approveRedeems(unlockedPoolId, scId, approvalRatio, payoutAssetId);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external poolUnlocked protected {
        IShareClassManager scm = poolRegistry.shareClassManager(unlockedPoolId);

        scm.issueShares(unlockedPoolId, scId, depositAssetId, navPerShare);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external
        poolUnlocked
        protected
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

    /// @inheritdoc IPoolManagerAdminMethods
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix)
        external
        poolUnlocked
        protected
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

    /// @inheritdoc IPoolManagerAdminMethods
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        poolUnlocked
        protected
    {
        uint128 valueChange = holdings.increase(unlockedPoolId, scId, assetId, valuation, amount);

        accounting.addCredit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.EQUITY)), valueChange);
        accounting.addDebit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.ASSET)), valueChange);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public
        poolUnlocked
        protected
    {
        uint128 valueChange = holdings.decrease(unlockedPoolId, scId, assetId, valuation, amount);

        accounting.addCredit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.ASSET)), valueChange);
        accounting.addDebit(holdings.accountId(unlockedPoolId, scId, assetId, uint8(AccountType.EQUITY)), valueChange);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function updateHolding(ShareClassId scId, AssetId assetId) external poolUnlocked protected {
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

    /// @inheritdoc IPoolManagerAdminMethods
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation)
        external
        poolUnlocked
        protected
    {
        holdings.updateValuation(unlockedPoolId, scId, assetId, valuation);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId)
        external
        poolUnlocked
        protected
    {
        holdings.setAccountId(unlockedPoolId, scId, assetId, accountId);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function createAccount(AccountId account, bool isDebitNormal) public poolUnlocked protected {
        accounting.createAccount(unlockedPoolId, account, isDebitNormal);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function setAccountMetadata(AccountId account, bytes calldata metadata) external poolUnlocked protected {
        accounting.setAccountMetadata(unlockedPoolId, account, metadata);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function addDebit(AccountId account, uint128 amount) external poolUnlocked protected {
        accounting.addDebit(account, amount);
    }

    /// @inheritdoc IPoolManagerAdminMethods
    function addCredit(AccountId account, uint128 amount) external poolUnlocked protected {
        accounting.addCredit(account, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManagerHandler
    function handleRegisterAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals)
        external
        onlyGateway
    {
        assetRegistry.registerAsset(assetId, name, symbol, decimals);
    }

    /// @inheritdoc IPoolManagerHandler
    function handleRequestDeposit(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId,
        uint128 amount
    ) external onlyGateway {
        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetRegistry.mint(pendingShareClassEscrow, depositAssetId.raw(), amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId, amount, investor, depositAssetId);
    }

    /// @inheritdoc IPoolManagerHandler
    function handleRequestRedeem(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId payoutAssetId,
        uint128 amount
    ) external onlyGateway {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestRedeem(poolId, scId, amount, investor, payoutAssetId);
    }

    /// @inheritdoc IPoolManagerHandler
    function handleCancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 cancelledAssetAmount) = scm.cancelDepositRequest(poolId, scId, investor, depositAssetId);

        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetRegistry.burn(pendingShareClassEscrow, depositAssetId.raw(), cancelledAssetAmount);

        gateway.sendFulfilledCancelDepositRequest(poolId, scId, depositAssetId, investor, cancelledAssetAmount);
    }

    /// @inheritdoc IPoolManagerHandler
    function handleCancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        uint128 cancelledShareAmount = scm.cancelRedeemRequest(poolId, scId, investor, payoutAssetId);

        gateway.sendFulfilledCancelRedeemRequest(poolId, scId, payoutAssetId, investor, cancelledShareAmount);
    }

    //----------------------------------------------------------------------------------------------
    // view / pure methods
    //----------------------------------------------------------------------------------------------

    function escrow(PoolId poolId, ShareClassId scId, EscrowId escrow_) public pure returns (address) {
        return address(bytes20(keccak256(abi.encodePacked("escrow", poolId, scId, escrow_))));
    }
}

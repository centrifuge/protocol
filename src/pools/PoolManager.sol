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
    IPoolManagerHandler,
    EscrowId,
    AccountType
} from "src/pools/interfaces/IPoolManager.sol";

// @inheritdoc IPoolManager
contract PoolManager is Auth, IPoolManager, IPoolManagerHandler {
    using MathLib for uint256;
    using CastLib for bytes;
    using CastLib for bytes32;
    using CastLib for address;

    IPoolRegistry public poolRegistry;
    IAssetRegistry public assetRegistry;
    IAccounting public accounting;
    IHoldings public holdings;
    IGateway public gateway;

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
    // System methods
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

    /// @inheritdoc IPoolManager
    function unlockAccounting(PoolId poolId) external auth {
        accounting.unlock(poolId, "TODO");
    }

    /// @inheritdoc IPoolManager
    function lockAccounting() external auth {
        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    // Permisionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function createPool(address admin, AssetId currency, IShareClassManager shareClassManager) external returns (PoolId poolId) {
        // TODO: add fees
        return poolRegistry.registerPool(admin, currency, shareClassManager);
    }

    /// @inheritdoc IPoolManager
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external auth {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimDeposit(poolId, scId, investor, assetId);
        gateway.sendFulfilledDepositRequest(poolId, scId, assetId, investor, tokens, shares);
    }

    /// @inheritdoc IPoolManager
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external auth {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 tokens, uint128 shares) = scm.claimRedeem(poolId, scId, investor, assetId);

        assetRegistry.burn(escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS), assetId.raw(), tokens);

        gateway.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, tokens, shares);
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManager
    function notifyPool(uint32 chainId, PoolId poolId) external auth {
        gateway.sendNotifyPool(chainId, poolId);
    }

    /// @inheritdoc IPoolManager
    function notifyShareClass(uint32 chainId, PoolId poolId, ShareClassId scId, bytes32 hook) external auth {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        require(scm.exists(poolId, scId), IShareClassManager.ShareClassNotFound());

        (string memory name, string memory symbol) = ISingleShareClass(address(scm)).metadata(scId);
        uint8 decimals = assetRegistry.decimals(poolRegistry.currency(poolId).raw());

        gateway.sendNotifyShareClass(chainId, poolId, scId, name, symbol, decimals, hook);
    }

    /// @inheritdoc IPoolManager
    function setPoolMetadata(PoolId poolId, bytes calldata metadata) external auth {
        poolRegistry.setMetadata(poolId, metadata);
    }

    /// @inheritdoc IPoolManager
    function allowPoolAdmin(PoolId poolId, address account, bool allow) external auth {
        poolRegistry.updateAdmin(poolId, account, allow);
    }

    /// @inheritdoc IPoolManager
    function allowAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool /*allow*/) external auth view {
        require(holdings.exists(poolId, scId, assetId), IHoldings.HoldingNotFound());

        // TODO: cal update contract feature
    }

    /// @inheritdoc IPoolManager
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes calldata data) external auth {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.addShareClass(poolId, name, symbol, data);
    }

    /// @inheritdoc IPoolManager
    function approveDeposits(PoolId poolId, ShareClassId scId, AssetId paymentAssetId, D18 approvalRatio, IERC7726 valuation)
        external auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 approvedAssetAmount,) =
            scm.approveDeposits(poolId, scId, approvalRatio, paymentAssetId, valuation);

        assetRegistry.authTransferFrom(
            escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS),
            escrow(poolId, scId, EscrowId.SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(paymentAssetId))),
            approvedAssetAmount
        );

        increaseHolding(poolId, scId, paymentAssetId, valuation, approvedAssetAmount);
    }

    /// @inheritdoc IPoolManager
    function approveRedeems(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio)
        external auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        scm.approveRedeems(poolId, scId, approvalRatio, payoutAssetId);
    }

    /// @inheritdoc IPoolManager
    function issueShares(PoolId poolId, ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external auth {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        scm.issueShares(poolId, scId, depositAssetId, navPerShare);
    }

    /// @inheritdoc IPoolManager
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation)
        external auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 payoutAssetAmount,) = scm.revokeShares(poolId, scId, payoutAssetId, navPerShare, valuation);

        assetRegistry.authTransferFrom(
            escrow(poolId, scId, EscrowId.SHARE_CLASS),
            escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(payoutAssetId))),
            payoutAssetAmount
        );

        decreaseHolding(poolId, scId, payoutAssetId, valuation, payoutAssetAmount);
    }

    /// @inheritdoc IPoolManager
    function createHolding(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix)
        external auth
    {
        require(assetRegistry.isRegistered(assetId), IAssetRegistry.AssetNotFound());

        AccountId[] memory accounts = new AccountId[](4);
        accounts[0] = newAccountId(prefix, uint8(AccountType.ASSET));
        accounts[1] = newAccountId(prefix, uint8(AccountType.EQUITY));
        accounts[2] = newAccountId(prefix, uint8(AccountType.LOSS));
        accounts[3] = newAccountId(prefix, uint8(AccountType.GAIN));

        createAccount(poolId, accounts[0], true);
        createAccount(poolId, accounts[1], false);
        createAccount(poolId, accounts[2], false);
        createAccount(poolId, accounts[3], false);

        holdings.create(poolId, scId, assetId, valuation, accounts);
    }

    /// @inheritdoc IPoolManager
    function increaseHolding(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public auth
    {
        uint128 valueChange = holdings.increase(poolId, scId, assetId, valuation, amount);

        accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.EQUITY)), valueChange);
        accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)), valueChange);
    }

    /// @inheritdoc IPoolManager
    function decreaseHolding(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        public auth
    {
        uint128 valueChange = holdings.decrease(poolId, scId, assetId, valuation, amount);

        accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)), valueChange);
        accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.EQUITY)), valueChange);
    }

    /// @inheritdoc IPoolManager
    function updateHolding(PoolId poolId, ShareClassId scId, AssetId assetId) external auth {
        int128 diff = holdings.update(poolId, scId, assetId);

        if (diff > 0) {
            accounting.addCredit(
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.GAIN)), uint128(diff)
            );
            accounting.addDebit(
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)), uint128(diff)
            );
        } else if (diff < 0) {
            accounting.addCredit(
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.ASSET)), uint128(diff)
            );
            accounting.addDebit(
                holdings.accountId(poolId, scId, assetId, uint8(AccountType.LOSS)), uint128(diff)
            );
        }
    }

    /// @inheritdoc IPoolManager
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation)
        external auth
    {
        holdings.updateValuation(poolId, scId, assetId, valuation);
    }

    /// @inheritdoc IPoolManager
    function setHoldingAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, AccountId accountId)
        external auth
    {
        holdings.setAccountId(poolId, scId, assetId, accountId);
    }

    /// @inheritdoc IPoolManager
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) public auth {
        accounting.createAccount(poolId, account, isDebitNormal);
    }

    /// @inheritdoc IPoolManager
    function setAccountMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external auth {
        accounting.setAccountMetadata(poolId, account, metadata);
    }

    /// @inheritdoc IPoolManager
    function addDebit(AccountId account, uint128 amount) external auth {
        accounting.addDebit(account, amount);
    }

    /// @inheritdoc IPoolManager
    function addCredit(AccountId account, uint128 amount) external auth {
        accounting.addCredit(account, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolManagerHandler
    function registerAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals)
        external auth
    {
        assetRegistry.registerAsset(assetId, name, symbol, decimals);
    }

    /// @inheritdoc IPoolManagerHandler
    function depositRequest(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId,
        uint128 amount
    ) external auth {
        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetRegistry.mint(pendingShareClassEscrow, depositAssetId.raw(), amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId, amount, investor, depositAssetId);
    }

    /// @inheritdoc IPoolManagerHandler
    function redeemRequest(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId payoutAssetId,
        uint128 amount
    ) external auth {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestRedeem(poolId, scId, amount, investor, payoutAssetId);
    }

    /// @inheritdoc IPoolManagerHandler
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external auth
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 cancelledAssetAmount) = scm.cancelDepositRequest(poolId, scId, investor, depositAssetId);

        address pendingShareClassEscrow = escrow(poolId, scId, EscrowId.PENDING_SHARE_CLASS);
        assetRegistry.burn(pendingShareClassEscrow, depositAssetId.raw(), cancelledAssetAmount);

        gateway.sendFulfilledCancelDepositRequest(poolId, scId, depositAssetId, investor, cancelledAssetAmount);
    }

    /// @inheritdoc IPoolManagerHandler
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId)
        external auth
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

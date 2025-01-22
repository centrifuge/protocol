// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainId} from "src/types/ChainId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {GlobalAddress} from "src/types/GlobalAddress.sol";
import {ItemId} from "src/types/ItemId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {D18} from "src/types/D18.sol";

import {IAssetManager, IAccounting, IGateway} from "src/interfaces/ICommon.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {IPoolManager, Escrow, AccountType} from "src/interfaces/IPoolManager.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {IERC7726, IERC7726Ext} from "src/interfaces/IERC7726.sol";

import {MathLib} from "src/libraries/MathLib.sol";

import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

contract PoolManager is Auth, PoolLocker, IPoolManager {
    using MathLib for uint256;

    IPoolRegistry poolRegistry;
    IAssetManager assetManager;
    IAccounting accounting;
    IHoldings holdings;
    IGateway gateway;

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

    function createPool(IERC20Metadata currency, IShareClassManager shareClassManager)
        external
        returns (PoolId poolId)
    {
        // TODO: add fees
        return poolRegistry.registerPool(msg.sender, currency, shareClassManager);
    }

    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimDeposit(poolId, scId.toBytes(), assetId.addr(), investor.addr());
        gateway.sendFulfilledDepositRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimRedeem(poolId, scId.toBytes(), assetId.addr(), investor.addr());

        assetManager.burn(_escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS), assetId, tokens);

        gateway.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    //----------------------------------------------------------------------------------------------
    // Pool admin methods
    //----------------------------------------------------------------------------------------------

    function notifyPool(ChainId chainId) external poolUnlocked {
        gateway.sendNotifyPool(chainId, unlockedPoolId());
    }

    function notifyShareClass(ChainId chainId, ShareClassId scId) external poolUnlocked {
        // TODO: check scId existence
        gateway.sendNotifyShareClass(chainId, unlockedPoolId(), scId);
    }

    function notifyAllowedAsset(ShareClassId scId, AssetId assetId) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        gateway.sendNotifyAllowedAsset(poolId, scId, assetId, poolRegistry.isInvestorAssetAllowed(poolId, assetId));
    }

    function setPoolMetadata(bytes calldata metadata) external {
        poolRegistry.setMetadata(unlockedPoolId(), metadata);
    }

    function setPoolAdmin(address newAdmin, bool canManage) external {
        poolRegistry.updateAdmin(unlockedPoolId(), newAdmin, canManage);
    }

    function allowInvestorAsset(AssetId assetId, bool isAllowed) external {
        PoolId poolId = unlockedPoolId();

        require(assetManager.isRegistered(assetId), "AssetNotRegistered");
        require(holdings.isAssetAllowed(poolId, assetId), "HoldingAssetNotAllowed");

        poolRegistry.allowInvestorAsset(poolId, assetId, isAllowed);
    }

    function allowHoldingAsset(AssetId assetId, bool isAllowed) external {
        PoolId poolId = unlockedPoolId();

        if (!isAllowed) {
            require(!poolRegistry.isInvestorAssetAllowed(poolId, assetId), "InvestorAssetMustBeDisallowed");
        }

        holdings.allowAsset(poolId, assetId, isAllowed);
    }

    function addShareClass(bytes calldata data) external returns (ShareClassId) {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        return ShareClassId.wrap(uint128(scm.addShareClass(poolId, data)));
    }

    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, D18 approvalRatio) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        ItemId itemId = holdings.itemId(poolId, scId, paymentAssetId);
        IERC7726 valuation = holdings.valuation(poolId, itemId);

        (, uint128 approvedAssetAmount) = scm.approveDeposits(
            poolId, scId.toBytes(), approvalRatio, paymentAssetId.addr(), IERC7726Ext(address(valuation))
        );

        // TODO: approve this contract to perform the transfer on behalf.

        assetManager.transferFrom(
            _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS),
            _escrow(poolId, scId, Escrow.SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(paymentAssetId))),
            approvedAssetAmount
        );
    }

    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        ItemId itemId = holdings.itemId(poolId, scId, payoutAssetId);
        IERC7726 valuation = holdings.valuation(poolId, itemId);

        scm.approveRedeems(poolId, scId.toBytes(), approvalRatio, payoutAssetId.addr(), IERC7726Ext(address(valuation)));
    }

    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        scm.issueShares(poolId, scId.toBytes(), depositAssetId.addr(), navPerShare);
    }

    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 payoutAssetAmount,) = scm.revokeShares(poolId, scId.toBytes(), payoutAssetId.addr(), navPerShare);

        // TODO: approve this contract to perform the transfer on behalf.

        assetManager.transferFrom(
            _escrow(poolId, scId, Escrow.SHARE_CLASS),
            _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(payoutAssetId))),
            payoutAssetAmount
        );
    }

    function createItem(IItemManager im, IERC7726 valuation, AccountId[] memory accounts, bytes calldata data)
        external
        poolUnlocked
    {
        im.create(unlockedPoolId(), valuation, accounts, data);
    }

    function closeItem(IItemManager im, ItemId itemId, bytes calldata data) external poolUnlocked {
        im.close(unlockedPoolId(), itemId, data);
    }

    function increaseItem(IItemManager im, ItemId itemId, IERC7726 valuation, uint128 amount) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        uint128 valueChange = im.increase(poolId, itemId, valuation, amount);

        accounting.updateEntry(
            im.accountId(poolId, itemId, uint8(AccountType.EQUITY)),
            im.accountId(poolId, itemId, uint8(AccountType.ASSET)),
            valueChange
        );
    }

    function decreaseItem(IItemManager im, ItemId itemId, IERC7726 valuation, uint128 amount) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        uint128 valueChange = im.decrease(poolId, itemId, valuation, amount);

        accounting.updateEntry(
            im.accountId(poolId, itemId, uint8(AccountType.ASSET)),
            im.accountId(poolId, itemId, uint8(AccountType.EQUITY)),
            valueChange
        );
    }

    function updateItem(IItemManager im, ItemId itemId) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        int128 diff = im.update(poolId, itemId);

        if (diff > 0) {
            accounting.updateEntry(
                im.accountId(poolId, itemId, uint8(AccountType.GAIN)),
                im.accountId(poolId, itemId, uint8(AccountType.ASSET)),
                uint128(diff)
            );
        } else if (diff < 0) {
            accounting.updateEntry(
                im.accountId(poolId, itemId, uint8(AccountType.ASSET)),
                im.accountId(poolId, itemId, uint8(AccountType.LOSS)),
                uint128(-diff)
            );
        }
    }

    function updateItemValuation(IItemManager im, ItemId itemId, IERC7726 valuation) external poolUnlocked {
        im.updateValuation(unlockedPoolId(), itemId, valuation);
    }

    function setItemAccountId(IItemManager im, ItemId itemId, AccountId accountId) external poolUnlocked {
        im.setAccountId(unlockedPoolId(), itemId, accountId);
    }

    function updateEntry(AccountId credit, AccountId debit, uint128 amount) external poolUnlocked {
        accounting.updateEntry(credit, debit, amount);
    }

    function unlockTokens(ShareClassId scId, AssetId assetId, GlobalAddress receiver, uint128 assetAmount)
        external
        poolUnlocked
    {
        assetManager.burn(_escrow(unlockedPoolId(), scId, Escrow.SHARE_CLASS), assetId, assetAmount);

        gateway.sendUnlockTokens(assetId, receiver, assetAmount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    function notifyRegisteredAsset(AssetId assetId) external onlyGateway {
        // TODO: register in the asset registry
    }

    function requestDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        GlobalAddress investor,
        uint128 amount
    ) external onlyGateway {
        address pendingShareClassEscrow = _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS);
        assetManager.mint(pendingShareClassEscrow, depositAssetId, amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId.toBytes(), amount, investor.addr(), depositAssetId.addr());
    }

    function requestRedeem(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        GlobalAddress investor,
        uint128 amount
    ) external onlyGateway {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestRedeem(poolId, scId.toBytes(), amount, investor.addr(), payoutAssetId.addr());
    }

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId depositAssetId, GlobalAddress investor)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 cancelledAssetAmount) =
            scm.cancelDepositRequest(poolId, scId.toBytes(), investor.addr(), depositAssetId.addr());

        address pendingShareClassEscrow = _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS);
        assetManager.burn(pendingShareClassEscrow, depositAssetId, cancelledAssetAmount);

        gateway.sendFulfilledCancelDepositRequest(
            poolId, scId, depositAssetId, investor, cancelledAssetAmount, cancelledAssetAmount
        );
    }

    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, GlobalAddress investor)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        uint128 cancelledAssetAmount =
            scm.cancelRedeemRequest(poolId, scId.toBytes(), investor.addr(), payoutAssetId.addr());

        gateway.sendFulfilledRedeemRequest(
            poolId, scId, payoutAssetId, investor, cancelledAssetAmount, cancelledAssetAmount
        );
    }

    function notifyLockedTokens(AssetId assetId, address recvAddr, uint128 amount) external onlyGateway {
        assetManager.mint(recvAddr, assetId, amount);
    }

    //----------------------------------------------------------------------------------------------
    // internal / private
    //----------------------------------------------------------------------------------------------

    function _beforeLock() internal override {
        accounting.lock(unlockedPoolId());
    }

    function _beforeUnlock(PoolId poolId) internal view override {
        require(poolRegistry.isAdmin(poolId, msg.sender));
    }

    function _escrow(PoolId poolId, ShareClassId scId, Escrow escrow) private view returns (address) {
        bytes32 key = keccak256(abi.encodePacked(scId, "escrow", escrow));
        return poolRegistry.addressFor(poolId, key);
    }
}

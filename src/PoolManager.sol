// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainId, Ratio} from "src/types/Domain.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {GlobalAddress} from "src/types/GlobalAddress.sol";
import {ItemId} from "src/types/ItemId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IAssetManager, IAccounting, IGateway} from "src/interfaces/ICommon.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {IPoolManager, Escrow} from "src/interfaces/IPoolManager.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

import {MathLib} from "src/libraries/MathLib.sol";

import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

enum AccountType {
    ASSET,
    EQUITY,
    LOSS,
    GAIN
}

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

    function claimShares(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimShares(poolId, scId, assetId, investor);
        gateway.sendFulfilledDepositRequest(poolId, scId, assetId, investor, shares, tokens);
    }

    function claimTokens(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        (uint128 shares, uint128 tokens) = scm.claimShares(poolId, scId, assetId, investor);

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
        gateway.sendNotifyShareClass(chainId, unlockedPoolId(), scId);
    }

    function notifyAllowedAsset(ChainId chainId, ShareClassId scId, AssetId assetId, bool isAllowed)
        external
        poolUnlocked
    {
        gateway.sendNotifyAllowedAsset(chainId, unlockedPoolId(), scId, assetId, isAllowed);
    }

    function allowAsset(ShareClassId scId, AssetId assetId, bool isAllowed) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.allowAsset(unlockedPoolId(), scId, assetId, isAllowed);
    }

    function approveDeposit(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        ItemId itemId = holdings.itemIdFromAsset(poolId, scId, assetId);
        IERC7726 valuation = holdings.valuation(poolId, itemId);

        uint128 totalApproved = scm.approveDeposit(poolId, scId, assetId, approvalRatio, valuation);

        assetManager.transferFrom(
            _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS),
            _escrow(poolId, scId, Escrow.SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(assetId))),
            totalApproved
        );
    }

    function approveRedeem(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        ItemId itemId = holdings.itemIdFromAsset(poolId, scId, assetId);
        IERC7726 valuation = holdings.valuation(poolId, itemId);

        scm.approveDeposit(poolId, scId, assetId, approvalRatio, valuation);
    }

    function issueShares(ShareClassId scId, uint128 navPerShare) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        scm.issueShares(poolId, scId, navPerShare);
    }

    function revokeShares(ShareClassId scId, AssetId assetId, uint128 navPerShare) external poolUnlocked {
        PoolId poolId = unlockedPoolId();

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);

        uint128 amount = scm.revokeShares(poolId, scId, navPerShare);

        assetManager.transferFrom(
            _escrow(poolId, scId, Escrow.SHARE_CLASS),
            _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS),
            uint256(uint160(AssetId.unwrap(assetId))),
            amount
        );
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

    function unlockTokens(ShareClassId scId, AssetId assetId, GlobalAddress receiver, uint128 assetAmount)
        external
        poolUnlocked
    {
        PoolId poolId = unlockedPoolId();

        assetManager.burn(_escrow(poolId, scId, Escrow.SHARE_CLASS), assetId, assetAmount);

        gateway.sendUnlockTokens(assetId, receiver, assetAmount);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    function notifyRegisteredAsset(AssetId assetId) external onlyGateway {
        // TODO: register in the asset registry
    }

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor, uint128 amount)
        external
        onlyGateway
    {
        address pendingShareClassEscrow = _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS);
        assetManager.mint(pendingShareClassEscrow, assetId, amount);

        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestDeposit(poolId, scId, assetId, investor, amount);
    }

    function requestRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor, uint128 amount)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        scm.requestRedeem(poolId, scId, assetId, investor, amount);
    }

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 canceled, uint128 fulfilled) = scm.cancelDepositRequest(poolId, scId, assetId, investor);

        address pendingShareClassEscrow = _escrow(poolId, scId, Escrow.PENDING_SHARE_CLASS);
        assetManager.burn(pendingShareClassEscrow, assetId, canceled);

        gateway.sendFulfilledCancelDepositRequest(poolId, scId, assetId, investor, canceled, fulfilled);
    }

    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor)
        external
        onlyGateway
    {
        IShareClassManager scm = poolRegistry.shareClassManager(poolId);
        (uint128 canceled, uint128 fulfilled) = scm.cancelRedeemRequest(poolId, scId, assetId, investor);

        gateway.sendFulfilledRedeemRequest(poolId, scId, assetId, investor, canceled, fulfilled);
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {IVaultMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {IBalanceSheetGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {ISharePriceProvider, Prices} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";

struct QueueAmount {
    uint128 increase; // issuances + deposits
    uint128 decrease; // revocations + withdraws
}

contract BalanceSheet is Auth, Recoverable, IBalanceSheet, IBalanceSheetGatewayHandler, IUpdateContract {
    using MathLib for *;
    using CastLib for bytes32;

    IGateway public gateway;
    IPoolManager public poolManager;
    IVaultMessageSender public sender;
    ISharePriceProvider public sharePriceProvider;
    IPoolEscrowProvider public poolEscrowProvider;

    mapping(PoolId => mapping(ShareClassId => mapping(address => bool))) public manager;

    mapping(PoolId poolId => mapping(ShareClassId scId => QueueAmount)) public queuedShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => bool)) public queuedSharesEnabled;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => QueueAmount))) public queuedAssets;
    mapping(PoolId poolId => mapping(ShareClassId scId => bool)) public queuedAssetsEnabled;

    constructor(address deployer) Auth(deployer) {}

    /// @dev Check if the msg.sender has managers
    modifier authOrManager(PoolId poolId, ShareClassId scId) {
        require(wards[msg.sender] == 1 || manager[poolId][scId][msg.sender], IAuth.NotAuthorized());
        _;
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "sharePriceProvider") sharePriceProvider = ISharePriceProvider(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// --- IUpdateContract Implementation ---
    function update(PoolId poolId, ShareClassId scId, bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateManager)) {
            MessageLib.UpdateContractUpdateManager memory m = MessageLib.deserializeUpdateContractUpdateManager(payload);

            address who = m.who.toAddress();

            manager[poolId][scId][who] = m.canManage;

            emit UpdateManager(poolId, scId, who, m.canManage);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    /// --- External ---
    /// @inheritdoc IBalanceSheet
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, address provider, uint128 amount)
        external
        authOrManager(poolId, scId)
    {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, true);
    }

    /// @inheritdoc IBalanceSheet
    function deposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset, true);
    }

    /// @inheritdoc IBalanceSheet
    function noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset, false);
    }

    /// @inheritdoc IBalanceSheet
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);

        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IBalanceSheet
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, pricePoolPerAsset);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _revoke(poolId, scId, from, shares);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares, D18 price)
        external
        authOrManager(poolId, scId)
    {
        _revoke(poolId, scId, from, shares, price);
    }

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external authOrManager(poolId, scId) {
        _issue(poolId, scId, to, shares);
    }

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares, D18 price)
        external
        authOrManager(poolId, scId)
    {
        _issue(poolId, scId, to, shares, price);
    }

    /// @inheritdoc IBalanceSheet
    function transferSharesFrom(PoolId poolId, ShareClassId scId, address from, address to, uint256 amount)
        external
        authOrManager(poolId, scId)
    {
        IShareToken token = IShareToken(poolManager.shareToken(poolId, scId));
        token.authTransferFrom(from, from, to, amount);
    }

    /// --- IBalanceSheetHandler ---
    /// @inheritdoc IBalanceSheetGatewayHandler
    function enableSharesQueue(PoolId poolId, ShareClassId scId, bool enabled) external auth {
        queuedSharesEnabled[poolId][scId] = enabled;
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function enableAssetsQueue(PoolId poolId, ShareClassId scId, bool enabled) external auth {
        queuedAssetsEnabled[poolId][scId] = enabled;
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function submitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        authOrManager(poolId, scId)
    {
        _submitQueuedAssets(poolId, scId, assetId);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function submitQueuedShares(PoolId poolId, ShareClassId scId) external authOrManager(poolId, scId) {
        _submitQueuedShares(poolId, scId);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address provider, uint128 amount)
        external
        auth
    {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);

        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, true);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerWithdraw(PoolId poolId, ShareClassId scId, AssetId assetId, address receiver, uint128 amount)
        external
        auth
    {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address to, uint128 shares) external auth {
        _issue(poolId, scId, to, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerRevokeShares(PoolId poolId, ShareClassId scId, address from, uint128 shares) external auth {
        _revoke(poolId, scId, from, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function approvedDeposits(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        Prices memory prices = sharePriceProvider.prices(poolId, scId, assetId, asset, tokenId);

        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        escrow.deposit(scId, asset, tokenId, assetAmount);
        sender.sendUpdateHoldingAmount(poolId, scId, assetId, address(escrow), assetAmount, prices.poolPerAsset, true);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function revokedShares(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);

        // Lock assets to ensure they are not withdrawn and are available for the redeeming user
        poolEscrowProvider.escrow(poolId).reserveIncrease(scId, asset, tokenId, assetAmount);
    }

    // --- Internal ---
    function _issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) internal {
        (D18 price,) = poolManager.pricePoolPerShare(poolId, scId, false);
        _issue(poolId, scId, to, shares, price);
    }

    function _issue(PoolId poolId, ShareClassId scId, address to, uint128 shares, D18 pricePoolPerShare) internal {
        IShareToken token = poolManager.shareToken(poolId, scId);
        token.mint(address(to), shares);

        if (queuedSharesEnabled[poolId][scId]) {
            queuedShares[poolId][scId].increase += shares;
        } else {
            sender.sendUpdateShares(poolId, scId, shares, true);
        }

        emit Issue(poolId, scId, to, pricePoolPerShare, shares);
    }

    function _revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares) internal {
        (D18 price,) = poolManager.pricePoolPerShare(poolId, scId, false);
        _revoke(poolId, scId, from, shares, price);
    }

    function _revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares, D18 pricePoolPerShare) internal {
        IShareToken token = poolManager.shareToken(poolId, scId);
        token.burn(address(from), shares);

        emit Revoke(poolId, scId, from, pricePoolPerShare, shares);

        if (queuedSharesEnabled[poolId][scId]) {
            queuedShares[poolId][scId].decrease += shares;
        } else {
            sender.sendUpdateShares(poolId, scId, shares, false);
        }
    }

    function _deposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        bool preDepositTransfer
    ) internal {
        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);
        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset, preDepositTransfer);
    }

    function _deposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool preDepositTransfer
    ) internal {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);

        if (preDepositTransfer) {
            if (tokenId == 0) {
                SafeTransferLib.safeTransferFrom(asset, provider, address(escrow), amount);
            } else {
                IERC6909(asset).transferFrom(provider, address(escrow), tokenId, amount);
            }
        }

        emit Deposit(poolId, scId, asset, tokenId, provider, amount, pricePoolPerAsset, uint64(block.timestamp));

        // Do escrow balance sufficiency check only if we executed the transfer
        if (preDepositTransfer) {
            escrow.deposit(scId, asset, tokenId, amount);
        } else {
            escrow.noteDeposit(scId, asset, tokenId, amount);
        }

        if (queuedAssetsEnabled[poolId][scId]) {
            queuedAssets[poolId][scId][assetId].increase += amount;
        } else {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, provider, amount, pricePoolPerAsset, true);
        }
    }

    function _withdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) internal {
        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, pricePoolPerAsset);
    }

    function _withdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    ) internal {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        escrow.withdraw(scId, asset, tokenId, amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, amount);
        } else {
            IERC6909(asset).transferFrom(address(escrow), receiver, tokenId, amount);
        }

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount, pricePoolPerAsset, uint64(block.timestamp));

        if (queuedAssetsEnabled[poolId][scId]) {
            queuedAssets[poolId][scId][assetId].decrease += amount;
        } else {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, receiver, amount, pricePoolPerAsset, false);
        }
    }

    function _submitQueuedShares(PoolId poolId, ShareClassId scId) internal {
        QueueAmount storage queue = queuedShares[poolId][scId];
        if (!queuedSharesEnabled[poolId][scId]) {
            return;
        }

        if (queue.increase > queue.decrease) {
            sender.sendUpdateShares(poolId, scId, queue.increase - queue.decrease, true);
        } else if (queue.decrease > queue.increase) {
            sender.sendUpdateShares(poolId, scId, queue.decrease - queue.increase, false);
        }

        queue.increase = 0;
        queue.decrease = 0;
    }

    function _submitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        QueueAmount storage queue = queuedAssets[poolId][scId][assetId];
        if (!queuedAssetsEnabled[poolId][scId]) {
            return;
        }

        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);

        if (queue.increase > queue.decrease) {
            sender.sendUpdateHoldingAmount(
                poolId, scId, assetId, address(0), queue.increase - queue.decrease, pricePoolPerAsset, true
            );
        } else if (queue.decrease > queue.increase) {
            sender.sendUpdateHoldingAmount(
                poolId, scId, assetId, address(0), queue.decrease - queue.increase, pricePoolPerAsset, false
            );
        }

        queue.increase = 0;
        queue.decrease = 0;
    }
}

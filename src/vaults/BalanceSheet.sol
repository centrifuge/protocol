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
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {ISharePriceProvider, Prices} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

contract BalanceSheet is Auth, Recoverable, IBalanceSheet, IBalanceSheetGatewayHandler, IUpdateContract {
    using MathLib for *;
    using CastLib for bytes32;

    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IPoolManager public poolManager;
    IVaultMessageSender public sender;
    ISharePriceProvider public sharePriceProvider;

    mapping(PoolId => mapping(ShareClassId => mapping(address => bool))) public manager;
    mapping(PoolId poolId => mapping(ShareClassId scId => int128 amount)) public queuedShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => int128))) public queuedAssets;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = IPerPoolEscrow(escrow_);
    }

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
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// --- IUpdateContract Implementation ---
    function update(uint64 poolId_, bytes16 scId_, bytes calldata payload) external auth {
        uint8 kind = uint8(MessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateManager)) {
            MessageLib.UpdateContractUpdateManager memory m = MessageLib.deserializeUpdateContractUpdateManager(payload);

            PoolId poolId = PoolId.wrap(poolId_);
            ShareClassId scId = ShareClassId.wrap(scId_);
            address who = m.who.toAddress();

            manager[poolId][scId][who] = m.canManage;

            emit UpdateManager(poolId, scId, who, m.canManage);
        } else {
            revert UnknownUpdateContractType();
        }
    }

    /// --- External ---
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
        AssetId assetId = AssetId.wrap(poolManager.assetToId(asset, tokenId));
        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePoolPerAsset);
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
        AssetId assetId = AssetId.wrap(poolManager.assetToId(asset, tokenId));
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, pricePoolPerAsset);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _revoke(poolId, scId, from, pricePoolPerShare, shares);
    }

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, D18 pricePoolPerShare, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _issue(poolId, scId, to, pricePoolPerShare, shares);
    }

    /// @inheritdoc IBalanceSheet
    function transferSharesFrom(PoolId poolId, ShareClassId scId, address from, address to, uint256 amount)
        external
        authOrManager(poolId, scId)
    {
        IShareToken token = IShareToken(poolManager.shareToken(poolId.raw(), scId.raw()));
        token.authTransferFrom(from, from, to, amount);
    }

    /// --- IBalanceSheetHandler ---
    /// @inheritdoc IBalanceSheetGatewayHandler
    function sendQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) external authOrManager(poolId, scId) {
        _sendQueuedAssets(poolId, scId, assetId);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function sendQueuedShares(PoolId poolId, ShareClassId scId) external authOrManager(poolId, scId) {
        _sendQueuedShares(poolId, scId);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 priceAssetPerShare
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());

        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, priceAssetPerShare);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerWithdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address receiver,
        uint128 amount,
        D18 priceAssetPerShare
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, priceAssetPerShare);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address to, D18 pricePoolPerShare, uint128 shares)
        external
        auth
    {
        _issue(poolId, scId, to, pricePoolPerShare, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerRevokeShares(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares)
        external
        auth
    {
        _revoke(poolId, scId, from, pricePoolPerShare, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function approvedDeposits(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());
        Prices memory prices = sharePriceProvider.prices(poolId.raw(), scId.raw(), assetId.raw(), asset, tokenId);

        escrow.deposit(asset, tokenId, poolId.raw(), scId.raw(), assetAmount);
        sender.sendUpdateHoldingAmount(poolId, scId, assetId, address(escrow), assetAmount, prices.poolPerAsset, true);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function revokedShares(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount) external auth {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());
        escrow.reserveIncrease(asset, tokenId, poolId.raw(), scId.raw(), assetAmount);
    }

    // --- Internal ---
    function _issue(PoolId poolId, ShareClassId scId, address to, D18 pricePoolPerShare, uint128 shares) internal {
        address token = poolManager.shareToken(poolId.raw(), scId.raw());
        IShareToken(token).mint(address(to), shares);

        queuedShares[poolId][scId] += int128(shares);
        emit Issue(poolId, scId, to, pricePoolPerShare, shares);
    }

    function _revoke(PoolId poolId, ShareClassId scId, address from, D18 pricePoolPerShare, uint128 shares) internal {
        address token = poolManager.shareToken(poolId.raw(), scId.raw());
        IShareToken(token).burn(address(from), shares);

        queuedShares[poolId][scId] -= int128(shares);
        emit Revoke(poolId, scId, from, pricePoolPerShare, shares);
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
        escrow.withdraw(asset, tokenId, poolId.raw(), scId.raw(), amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, amount);
        } else {
            IERC6909(asset).transferFrom(address(escrow), receiver, tokenId, amount);
        }

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount, pricePoolPerAsset, uint64(block.timestamp));

        queuedAssets[poolId][scId][assetId] -= int128(amount);
    }

    function _deposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset
    ) internal {
        escrow.pendingDepositIncrease(asset, tokenId, poolId.raw(), scId.raw(), amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, provider, address(escrow), amount);
        } else {
            IERC6909(asset).transferFrom(provider, address(escrow), tokenId, amount);
        }

        escrow.deposit(asset, tokenId, poolId.raw(), scId.raw(), amount);
        queuedAssets[poolId][scId][assetId] += int128(amount);

        emit Deposit(poolId, scId, asset, tokenId, provider, amount, pricePoolPerAsset, uint64(block.timestamp));
    }

    function _sendQueuedShares(PoolId poolId, ShareClassId scId) internal {
        int128 shares = queuedShares[poolId][scId];
        (D18 pricePoolPerShare,) = poolManager.pricePoolPerShare(poolId.raw(), scId.raw(), true);

        if (shares > 0) {
            sender.sendUpdateShares(poolId, scId, pricePoolPerShare, uint128(shares), true);
        } else if (shares < 0) {
            sender.sendUpdateShares(poolId, scId, pricePoolPerShare, uint128(-shares), false);
        }

        queuedShares[poolId][scId] = 0;
    }

    function _sendQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        int128 amount = queuedAssets[poolId][scId][assetId];
        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId.raw(), scId.raw(), assetId.raw(), true);

        if (amount > 0) {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, address(0), uint128(amount), pricePoolPerAsset, true);
        } else if (amount < 0) {
            sender.sendUpdateHoldingAmount(
                poolId, scId, assetId, address(0), uint128(-amount), pricePoolPerAsset, false
            );
        }

        queuedAssets[poolId][scId][assetId] = 0;
    }
}

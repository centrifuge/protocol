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
    function transferSharesFrom(PoolId poolId, ShareClassId scId, address from, address to, uint256 amount)
        external
        authOrManager(poolId, scId)
    {
        IShareToken token = IShareToken(poolManager.shareToken(poolId, scId));
        token.authTransferFrom(from, from, to, amount);
    }

    /// @inheritdoc IBalanceSheet
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, address provider, uint128 amount)
        external
        authOrManager(poolId, scId)
    {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _noteDeposit(poolId, scId, assetId, asset, tokenId, provider, amount);
        _executeDeposit(poolId, asset, tokenId, provider, amount);
    }

    /// @inheritdoc IBalanceSheet
    /// @dev This function is mostly useful to keep higher level integrations CEI adherent.
    function noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount
    ) external authOrManager(poolId, scId) {
        AssetId assetId = poolManager.assetToId(asset, tokenId);
        _noteDeposit(poolId, scId, assetId, asset, tokenId, provider, amount);
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
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external authOrManager(poolId, scId) {
        _issue(poolId, scId, to, shares);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _noteRevoke(poolId, scId, from, shares);
        _executeRevoke(poolId, scId, from, shares);
    }

    /// @inheritdoc IBalanceSheet
    /// @dev This function is mostly useful to keep higher level integrations CEI adherent.
    function noteRevoke(PoolId poolId, ShareClassId scId, address from, uint128 shares)
        external
        authOrManager(poolId, scId)
    {
        _noteRevoke(poolId, scId, from, shares);
    }

    /// --- IBalanceSheetHandler ---
    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address provider, uint128 amount)
        external
        auth
    {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        _noteDeposit(poolId, scId, assetId, asset, tokenId, provider, amount);
        _executeDeposit(poolId, asset, tokenId, provider, amount);
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
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address receiver, uint128 shares)
    external
    auth
    {
        _issue(poolId, scId, receiver, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerRevokeShares(PoolId poolId, ShareClassId scId, address provider, uint128 shares)
    external
    auth
    {
        _noteRevoke(poolId, scId, provider, shares);
        _executeRevoke(poolId, scId, provider, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function setSharesQueue(PoolId poolId, ShareClassId scId, bool enabled) external auth {
        queuedSharesEnabled[poolId][scId] = enabled;
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function setAssetsQueue(PoolId poolId, ShareClassId scId, bool enabled) external auth {
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

    // --- Internal ---
    function _noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount
    ) internal {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        escrow.deposit(scId, asset, tokenId, amount);
        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);
        emit Deposit(poolId, scId, asset, tokenId, provider, amount, pricePoolPerAsset);

        if (queuedAssetsEnabled[poolId][scId]) {
            queuedAssets[poolId][scId][assetId].increase += amount;
        } else {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, provider, amount, pricePoolPerAsset, true);
        }
    }

    function _executeDeposit(PoolId poolId, address asset, uint256 tokenId, address provider, uint128 amount)
        internal
    {
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, provider, address(escrow), amount);
        } else {
            IERC6909(asset).transferFrom(provider, address(escrow), tokenId, amount);
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
        IPoolEscrow escrow = poolEscrowProvider.escrow(poolId);
        escrow.withdraw(scId, asset, tokenId, amount);
        (D18 pricePoolPerAsset,) = poolManager.pricePoolPerAsset(poolId, scId, assetId, true);
        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount, pricePoolPerAsset);

        if (queuedAssetsEnabled[poolId][scId]) {
            queuedAssets[poolId][scId][assetId].decrease += amount;
        } else {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, receiver, amount, pricePoolPerAsset, false);
        }

        // TODO: More specific error would be great here
        escrow.authTransferTo(asset, tokenId, receiver, amount);
    }

    function _issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) internal {
        (D18 pricePoolPerShare,) = poolManager.pricePoolPerShare(poolId, scId, true);
        emit Issue(poolId, scId, to, pricePoolPerShare, shares);

        if (queuedSharesEnabled[poolId][scId]) {
            queuedShares[poolId][scId].increase += shares;
        } else {
            sender.sendUpdateShares(poolId, scId, shares, true);
        }

        IShareToken token = poolManager.shareToken(poolId, scId);
        token.mint(to, shares);
    }

    function _noteRevoke(PoolId poolId, ShareClassId scId, address from, uint128 shares)
        internal
    {
        (D18 pricePoolPerShare,) = poolManager.pricePoolPerShare(poolId, scId, true);
        emit Revoke(poolId, scId, from, pricePoolPerShare, shares);

        if (queuedSharesEnabled[poolId][scId]) {
            queuedShares[poolId][scId].decrease += shares;
        } else {
            sender.sendUpdateShares(poolId, scId, shares, false);
        }
    }

    function _executeRevoke(PoolId poolId, ShareClassId scId, address from, uint128 shares) internal {
        IShareToken token = poolManager.shareToken(poolId, scId);
        token.burn(from, shares);
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

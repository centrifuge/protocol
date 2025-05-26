// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {TransientStorageLib} from "src/misc/libraries/TransientStorageLib.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IBalanceSheetGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet, QueueAmount} from "src/spoke/interfaces/IBalanceSheet.sol";
import {IPoolEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IPoolEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IPoolEscrowProvider} from "src/spoke/factories/interfaces/IPoolEscrowFactory.sol";

/// @title  Balance Sheet
/// @notice Management contract that integrates all balance sheet functions of a pool:
///         - Issuing and revoking shares
///         - Depositing and withdrawing assets
///         - Force transferring shares
///
///         Share and asset updates to the Hub are optionally queued, to reduce the cost
///         per transaction. Dequeuing can be triggered locally by the manager or from the Hub.
contract BalanceSheet is Auth, Recoverable, IBalanceSheet, IBalanceSheetGatewayHandler {
    using MathLib for *;
    using CastLib for bytes32;

    IRoot public immutable root;

    ISpoke public spoke;
    IVaultMessageSender public sender;
    IPoolEscrowProvider public poolEscrowProvider;

    mapping(PoolId => mapping(address => bool)) public manager;
    mapping(PoolId poolId => mapping(ShareClassId scId => bool)) public queueEnabled;
    mapping(PoolId poolId => mapping(ShareClassId scId => QueueAmount)) public queuedShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => QueueAmount))) public queuedAssets;

    constructor(IRoot root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @dev Check if the msg.sender is ward or a manager
    modifier authOrManager(PoolId poolId) {
        require(wards[msg.sender] == 1 || manager[poolId][msg.sender], IAuth.NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpoke(data);
        else if (what == "sender") sender = IVaultMessageSender(data);
        else if (what == "poolEscrowProvider") poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Management functions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        authOrManager(poolId)
    {
        noteDeposit(poolId, scId, asset, tokenId, msg.sender, amount);

        address escrow_ = address(escrow(poolId));
        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, msg.sender, escrow_, amount);
        } else {
            IERC6909(asset).transferFrom(msg.sender, escrow_, tokenId, amount);
        }
    }

    /// @inheritdoc IBalanceSheet
    function noteDeposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address owner,
        uint128 amount
    ) public authOrManager(poolId) {
        AssetId assetId = spoke.assetToId(asset, tokenId);
        escrow(poolId).deposit(scId, asset, tokenId, amount);

        D18 pricePoolPerAsset_ = _pricePoolPerAsset(poolId, scId, assetId);
        emit Deposit(poolId, scId, asset, tokenId, owner, amount, pricePoolPerAsset_);

        if (queueEnabled[poolId][scId]) {
            queuedAssets[poolId][scId][assetId].increase += amount;
        } else {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, amount, pricePoolPerAsset_, true);
        }
    }

    /// @inheritdoc IBalanceSheet
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external authOrManager(poolId) {
        AssetId assetId = spoke.assetToId(asset, tokenId);
        IPoolEscrow escrow_ = escrow(poolId);
        escrow_.withdraw(scId, asset, tokenId, amount);

        D18 pricePoolPerAsset_ = _pricePoolPerAsset(poolId, scId, assetId);
        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount, pricePoolPerAsset_);

        if (queueEnabled[poolId][scId]) {
            queuedAssets[poolId][scId][assetId].decrease += amount;
        } else {
            sender.sendUpdateHoldingAmount(poolId, scId, assetId, amount, pricePoolPerAsset_, false);
        }

        escrow_.authTransferTo(asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) public authOrManager(poolId) {
        emit Issue(poolId, scId, to, _pricePoolPerShare(poolId, scId), shares);

        if (queueEnabled[poolId][scId]) {
            queuedShares[poolId][scId].increase += shares;
        } else {
            sender.sendUpdateShares(poolId, scId, shares, true);
        }

        IShareToken token = spoke.shareToken(poolId, scId);
        token.mint(to, shares);
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external authOrManager(poolId) {
        emit Revoke(poolId, scId, msg.sender, _pricePoolPerShare(poolId, scId), shares);

        if (queueEnabled[poolId][scId]) {
            queuedShares[poolId][scId].decrease += shares;
        } else {
            sender.sendUpdateShares(poolId, scId, shares, false);
        }

        IShareToken token = spoke.shareToken(poolId, scId);
        token.authTransferFrom(msg.sender, msg.sender, address(this), shares);
        token.burn(address(this), shares);
    }

    /// @inheritdoc IBalanceSheet
    function transferSharesFrom(PoolId poolId, ShareClassId scId, address from, address to, uint256 amount)
        external
        authOrManager(poolId)
    {
        require(!root.endorsed(from), CannotTransferFromEndorsedContract());
        IShareToken token = IShareToken(spoke.shareToken(poolId, scId));
        token.authTransferFrom(from, from, to, amount);
    }

    /// @inheritdoc IBalanceSheet
    function overridePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 value)
        external
        authOrManager(poolId)
    {
        TransientStorageLib.tstore(keccak256(abi.encode("pricePoolPerAsset", poolId, scId, assetId)), value.raw());
        TransientStorageLib.tstore(keccak256(abi.encode("pricePoolPerAssetIsSet", poolId, scId, assetId)), true);
    }

    /// @inheritdoc IBalanceSheet
    function resetPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external authOrManager(poolId) {
        TransientStorageLib.tstore(keccak256(abi.encode("pricePoolPerAssetIsSet", poolId, scId, assetId)), false);
    }

    /// @inheritdoc IBalanceSheet
    function overridePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 value) external authOrManager(poolId) {
        TransientStorageLib.tstore(keccak256(abi.encode("pricePoolPerShare", poolId, scId)), value.raw());
        TransientStorageLib.tstore(keccak256(abi.encode("pricePoolPerShareIsSet", poolId, scId)), true);
    }

    /// @inheritdoc IBalanceSheet
    function resetPricePoolPerShare(PoolId poolId, ShareClassId scId) external authOrManager(poolId) {
        TransientStorageLib.tstore(keccak256(abi.encode("pricePoolPerShareIsSet", poolId, scId)), false);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheet
    function escrow(PoolId poolId) public view returns (IPoolEscrow) {
        return poolEscrowProvider.escrow(poolId);
    }

    /// @inheritdoc IBalanceSheet
    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        public
        view
        returns (uint128)
    {
        return escrow(poolId).availableBalanceOf(scId, asset, tokenId);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBalanceSheetGatewayHandler
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address receiver, uint128 shares) external auth {
        issue(poolId, scId, receiver, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function setQueue(PoolId poolId, ShareClassId scId, bool enabled) external auth {
        queueEnabled[poolId][scId] = enabled;
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function submitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) external authOrManager(poolId) {
        _submitQueuedAssets(poolId, scId, assetId);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function submitQueuedShares(PoolId poolId, ShareClassId scId) external authOrManager(poolId) {
        _submitQueuedShares(poolId, scId);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _submitQueuedShares(PoolId poolId, ShareClassId scId) internal {
        QueueAmount storage queue = queuedShares[poolId][scId];

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

        D18 pricePoolPerAsset = _pricePoolPerAsset(poolId, scId, assetId);
        if (queue.increase > queue.decrease) {
            sender.sendUpdateHoldingAmount(
                poolId, scId, assetId, queue.increase - queue.decrease, pricePoolPerAsset, true
            );
        } else if (queue.decrease > queue.increase) {
            sender.sendUpdateHoldingAmount(
                poolId, scId, assetId, queue.decrease - queue.increase, pricePoolPerAsset, false
            );
        }

        queue.increase = 0;
        queue.decrease = 0;
    }

    function _pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) internal view returns (D18) {
        if (TransientStorageLib.tloadBool(keccak256(abi.encode("pricePoolPerAssetIsSet", poolId, scId, assetId)))) {
            return
                d18(TransientStorageLib.tloadUint128(keccak256(abi.encode("pricePoolPerAsset", poolId, scId, assetId))));
        }

        D18 pricePoolPerAsset = spoke.pricePoolPerAsset(poolId, scId, assetId, true);
        return pricePoolPerAsset;
    }

    function _pricePoolPerShare(PoolId poolId, ShareClassId scId) internal view returns (D18) {
        if (TransientStorageLib.tloadBool(keccak256(abi.encode("pricePoolPerShareIsSet", poolId, scId)))) {
            return d18(TransientStorageLib.tloadUint128(keccak256(abi.encode("pricePoolPerShare", poolId, scId))));
        }

        D18 pricePoolPerShare = spoke.pricePoolPerShare(poolId, scId, true);
        return pricePoolPerShare;
    }
}

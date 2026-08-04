// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpoke} from "./interfaces/ISpoke.sol";
import {IRegistrar} from "./interfaces/IRegistrar.sol";
import {IPoolEscrow} from "./interfaces/IPoolEscrow.sol";
import {IRequestRouter} from "./interfaces/IRequestRouter.sol";
import {ISnapshotQueue} from "./interfaces/ISnapshotQueue.sol";
import {ISpokeRegistry} from "./interfaces/ISpokeRegistry.sol";
import {ISpokeRequestManager} from "./interfaces/ISpokeRequestManager.sol";
import {IPoolEscrowProvider} from "./factories/interfaces/IPoolEscrowFactory.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {IERC20, IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";
import {IERC6909, IERC6909MetadataExt, TransferFailed} from "../../misc/interfaces/IERC6909.sol";

import {IGateway} from "../messaging/interfaces/IGateway.sol";
import {ISpokeMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IPolicy} from "../utils/interfaces/IPolicy.sol";
import {BatchedMulticall} from "../utils/BatchedMulticall.sol";

/// @title  Spoke
/// @notice Management contract that integrates all spoke-side operations of a pool:
///         - Registering assets
///         - Depositing and withdrawing assets
///         - Reserving assets (removing them from the hub-accounted holding)
///         - Issuing and revoking shares
///         - Cross-chain share transfers, request forwarding, and manager calls
///
///         Share and asset updates to the Hub are queued, to reduce the cost per transaction.
contract Spoke is BatchedMulticall, Auth, Recoverable, ISpoke {
    using CastLib for *;

    uint8 internal constant MAX_DECIMALS = 18;

    ISpokeMessageSender public sender;

    ISnapshotQueue public immutable snapshotQueue;
    ISpokeRegistry public immutable spokeRegistry;
    IPoolEscrowProvider public immutable poolEscrowProvider;

    constructor(
        IGateway gateway_,
        ISnapshotQueue queues_,
        ISpokeRegistry spokeRegistry_,
        IPoolEscrowProvider poolEscrowProvider_,
        address deployer
    ) Auth(deployer) BatchedMulticall(gateway_) {
        snapshotQueue = queues_;
        spokeRegistry = spokeRegistry_;
        poolEscrowProvider = poolEscrowProvider_;
    }

    /// @dev Manager-only, and must satisfy the pool's policy if one is installed.
    modifier enforced(PoolId poolId) {
        _enforce(poolId);
        _;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "sender") sender = ISpokeMessageSender(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Assets
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId, address refund)
        external
        payable
        protected
        returns (AssetId assetId)
    {
        uint8 decimals = _safeGetAssetDecimals(asset, tokenId);
        require(decimals <= MAX_DECIMALS, TooManyDecimals());

        string memory name;
        string memory symbol;
        if (tokenId == 0) {
            IERC20Metadata meta = IERC20Metadata(asset);
            name = meta.name();
            symbol = meta.symbol();
        } else {
            IERC6909MetadataExt meta = IERC6909MetadataExt(asset);
            name = meta.name(tokenId);
            symbol = meta.symbol(tokenId);
        }

        assetId = spokeRegistry.assetToId(asset, tokenId);
        bool isInitialization = assetId.isNull();
        if (isInitialization) {
            assetId = spokeRegistry.createAssetId(sender.localCentrifugeId(), asset, tokenId);
        }

        emit RegisterAsset(centrifugeId, assetId, asset, tokenId, name, symbol, decimals, isInitialization);
        sender.sendRegisterAsset{value: msgValue()}(centrifugeId, assetId, decimals, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Balance sheet: asset methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable
        enforced(poolId)
    {
        IPoolEscrow escrow_ = escrow(poolId);
        escrow_.deposit(scId, asset, tokenId, amount);
        _queueAssets(poolId, scId, asset, tokenId, amount, true);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, msgSender(), address(escrow_), amount);
        } else {
            require(IERC6909(asset).transferFrom(msgSender(), address(escrow_), tokenId, amount), TransferFailed());
        }
        emit Deposit(poolId, scId, msgSender(), asset, tokenId, amount);
    }

    /// @inheritdoc ISpoke
    function noteDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable
        enforced(poolId)
    {
        escrow(poolId).deposit(scId, asset, tokenId, amount);
        _queueAssets(poolId, scId, asset, tokenId, amount, true);

        emit NoteDeposit(poolId, scId, msgSender(), asset, tokenId, amount);
    }

    /// @inheritdoc ISpoke
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external payable enforced(poolId) {
        IPoolEscrow escrow_ = escrow(poolId);

        escrow_.withdraw(scId, asset, tokenId, receiver, amount);
        _queueAssets(poolId, scId, asset, tokenId, amount, false);
        escrow_.authTransferTo(asset, tokenId, receiver, amount);

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount);
    }

    /// @inheritdoc ISpoke
    function withdrawReserved(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        address reserver,
        bytes32 reason
    ) external payable enforced(poolId) {
        IPoolEscrow escrow_ = escrow(poolId);

        escrow_.unreserve(scId, asset, tokenId, amount, reserver, reason);
        escrow_.withdraw(scId, asset, tokenId, receiver, amount);
        escrow_.authTransferTo(asset, tokenId, receiver, amount);

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount);
    }

    /// @inheritdoc ISpoke
    function reserve(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        bytes32 reason
    ) external payable enforced(poolId) {
        escrow(poolId).reserve(scId, asset, tokenId, amount, reserver, reason);
        _queueAssets(poolId, scId, asset, tokenId, amount, false);
    }

    /// @inheritdoc ISpoke
    function unreserve(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        bytes32 reason
    ) external payable enforced(poolId) {
        escrow(poolId).unreserve(scId, asset, tokenId, amount, reserver, reason);
        _queueAssets(poolId, scId, asset, tokenId, amount, true);
    }

    /// @inheritdoc ISpoke
    function submitQueuedAssets(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 extraGasLimit,
        address refund
    ) external payable enforced(poolId) {
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushAssets(poolId, scId, assetId);
        sender.sendUpdateAssets{value: msgValue()}(poolId, scId, assetId, data, extraGasLimit, refund);
    }

    //----------------------------------------------------------------------------------------------
    // Balance sheet: share methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external payable enforced(poolId) {
        (IERC20 token, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        require(address(token) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());

        snapshotQueue.queueShares(poolId, scId, shares, true);
        registrar.mint(address(token), to, shares);

        emit Issue(poolId, scId, msgSender(), to, shares);
    }

    /// @inheritdoc ISpoke
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external payable enforced(poolId) {
        (IERC20 token, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        require(address(token) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());

        snapshotQueue.queueShares(poolId, scId, shares, false);
        SafeTransferLib.safeTransferFrom(address(token), msgSender(), address(this), shares);
        SafeTransferLib.safeApprove(address(token), address(registrar), shares);
        registrar.burn(address(token), address(this), shares);

        emit Revoke(poolId, scId, msgSender(), msgSender(), shares);
    }

    /// @inheritdoc ISpoke
    function withdrawShares(PoolId poolId, ShareClassId scId, address receiver, uint128 amount)
        external
        payable
        enforced(poolId)
    {
        IERC20 token = spokeRegistry.shareToken(poolId, scId);
        require(address(token) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());
        escrow(poolId).authTransferTo(address(token), 0, receiver, amount);

        emit WithdrawShares(poolId, scId, receiver, amount);
    }

    /// @inheritdoc ISpoke
    function submitQueuedShares(PoolId poolId, ShareClassId scId, uint128 extraGasLimit, address refund)
        external
        payable
        enforced(poolId)
    {
        ISpokeMessageSender.UpdateData memory data = snapshotQueue.flushShares(poolId, scId);
        sender.sendUpdateShares{value: msgValue()}(poolId, scId, data, extraGasLimit, refund);
    }

    /// @inheritdoc ISpoke
    function transferSharesFrom(
        PoolId poolId,
        ShareClassId scId,
        address sender_,
        address from,
        address to,
        uint256 amount
    ) external payable enforced(poolId) {
        (IERC20 token, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        require(address(token) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());
        registrar.authTransferFrom(address(token), sender_, from, to, amount);
        emit TransferSharesFrom(poolId, scId, sender_, from, to, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Bridging
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        address sender_,
        address owner,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) public payable protected {
        require(msgSender() == owner || wards[msgSender()] == 1, NotAuthorized());
        require(spokeRegistry.bridger(poolId, owner), NotBridger());
        require(amount != 0, EmptyAmount());

        (IERC20 share, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        require(address(share) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());
        require(centrifugeId != sender.localCentrifugeId(), LocalTransferNotAllowed());
        require(registrar.canBridge(address(share), owner, centrifugeId, amount), BridgeNotAllowed());

        SafeTransferLib.safeTransferFrom(address(share), owner, address(this), amount);
        SafeTransferLib.safeApprove(address(share), address(registrar), amount);
        registrar.burn(address(share), address(this), amount);

        emit InitiateTransferShares(centrifugeId, poolId, scId, sender_, owner, receiver, amount);

        sender.sendInitiateTransferShares{value: msgValue()}(
            centrifugeId,
            poolId,
            scId,
            sender_.toBytes32(),
            receiver,
            amount,
            extraGasLimit,
            remoteExtraGasLimit,
            refund
        );
    }

    /// @inheritdoc ISpoke
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable {
        crosschainTransferShares(
            centrifugeId, poolId, scId, receiver, msgSender(), msgSender(), amount, 0, remoteExtraGasLimit, msgSender()
        );
    }

    //----------------------------------------------------------------------------------------------
    // Requests & manager calls
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRequestRouter
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable {
        ISpokeRequestManager manager = spokeRegistry.requestManager(poolId);
        require(address(manager) != address(0), InvalidRequestManager());
        require(msg.sender == address(manager), NotAuthorized());

        sender.sendRequest{value: msgValue()}(poolId, scId, assetId, payload, extraGasLimit, unpaid, refund);
    }

    /// @inheritdoc ISpoke
    function managerCall(PoolId poolId, bytes32 target, bytes calldata payload, uint128 extraGasLimit, address refund)
        external
        payable
    {
        emit ManagerCall(poolId.centrifugeId(), poolId, target, payload, msgSender());

        sender.sendManagerCallFromSpoke{value: msgValue()}(
            poolId, target, payload, msgSender().toBytes32(), extraGasLimit, refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpoke
    function policy(PoolId poolId) external view returns (IPolicy) {
        return spokeRegistry.policy(poolId);
    }

    /// @inheritdoc ISpoke
    function escrow(PoolId poolId) public view returns (IPoolEscrow) {
        return poolEscrowProvider.escrow(poolId);
    }

    /// @inheritdoc ISpoke
    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        public
        view
        returns (uint128)
    {
        return escrow(poolId).availableBalanceOf(scId, asset, tokenId);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Reverts unless the resolved sender is a manager for `poolId`, then applies the pool's
    ///      policy if one is installed.
    function _enforce(PoolId poolId) internal {
        require(spokeRegistry.manager(poolId, msgSender()), NotManager());

        IPolicy policy_ = spokeRegistry.policy(poolId);
        if (address(policy_) != address(0)) policy_.enforce(poolId, msgSender(), msg.data);
    }

    /// @dev Accumulate the queued gross asset flow.
    function _queueAssets(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        bool isIncrease
    ) internal {
        snapshotQueue.queueAssets(poolId, scId, spokeRegistry.assetToId(asset, tokenId, true), amount, isIncrease);
    }

    function _safeGetAssetDecimals(address asset, uint256 tokenId) internal view returns (uint8) {
        bytes memory callData;

        if (tokenId == 0) {
            callData = abi.encodeCall(IERC20Metadata.decimals, ());
        } else {
            callData = abi.encodeCall(IERC6909MetadataExt.decimals, tokenId);
        }

        (bool success, bytes memory data) = asset.staticcall(callData);
        require(success && data.length >= 32, AssetMissingDecimals());

        return abi.decode(data, (uint8));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RequestMessageLib} from "./libraries/RequestMessageLib.sol";
import {IVaultRequestRouter} from "./interfaces/IVaultRequestRouter.sol";
import {RequestCallbackType, RequestCallbackMessageLib} from "./libraries/RequestCallbackMessageLib.sol";
import {
    IVaultRequestManager,
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "./interfaces/IVaultRequestManager.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {RequestId} from "../../core/types/RequestId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {ISpokeRequestManager} from "../../core/spoke/interfaces/ISpokeRequestManager.sol";
import {VaultDetails, ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {IVault} from "../interfaces/IVault.sol";
import {VaultRequestIdLib} from "../libraries/VaultRequestIdLib.sol";
import {ISubsidyManager} from "../../utils/interfaces/ISubsidyManager.sol";

/// @title  Vault Request Router
/// @notice The per-network singleton registered as every vault pool's request manager, and the only
///         vaults contract that speaks the request wire. Inbound, it decodes hub callbacks into typed
///         calls on the vault the request id names. Outbound, it serializes a linked vault's flushed
///         request, deriving the id from the calling vault, and sends it through the spoke.
contract VaultRequestRouter is Auth, IVaultRequestRouter {
    using VaultRequestIdLib for RequestId;
    using RequestCallbackMessageLib for bytes;

    ISpoke public immutable spoke;
    address public immutable envoy;
    ISpokeRegistry public immutable spokeRegistry;
    ISubsidyManager public immutable subsidyManager;

    mapping(PoolId => uint128) public extraGasLimit;

    constructor(
        ISpoke spoke_,
        ISpokeRegistry spokeRegistry_,
        ISubsidyManager subsidyManager_,
        address envoy_,
        address initialWard
    ) Auth(initialWard) {
        spoke = spoke_;
        spokeRegistry = spokeRegistry_;
        subsidyManager = subsidyManager_;
        envoy = envoy_;
    }

    /// @dev Holds the cross-chain subsidy a request withdraws from the subsidy manager until it pays the spoke.
    receive() external payable {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());
        uint128 extraGasLimit_ = abi.decode(payload, (uint128));
        extraGasLimit[poolId] = extraGasLimit_;
        emit SetExtraGasLimit(poolId, extraGasLimit_);
    }

    //----------------------------------------------------------------------------------------------
    // Inbound callbacks
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeRequestManager
    /// @dev The router is every pool's request manager, so the vault's `onlyRequestManager` does not
    ///      bind the pool; this registry check does, and the vault's own pool has to agree: the registry records
    ///      whatever a `DeployAndLink` factory returned, so a pool could register a vault another pool built.
    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external auth {
        RequestId requestId = payload.requestId();
        address vault = requestId.vaultOf();

        VaultDetails memory details = spokeRegistry.vaultDetails(vault);
        require(details.isLinked, NotLinked());
        require(details.poolId == poolId && IVault(vault).poolId() == poolId, WrongPool());
        require(details.scId == scId && details.assetId.raw() == assetId.raw(), WrongLane());
        uint96 localId = requestId.localIdOf();

        RequestCallbackType kind = payload.requestCallbackType();
        if (kind == RequestCallbackType.SettledDeposit) {
            // One message, applied as its three legs in this call, so no intermediate state is observable.
            RequestCallbackMessageLib.SettledDeposit memory m = payload.deserializeSettledDeposit();
            IVaultDepositCallbacks target = IVaultDepositCallbacks(vault);
            target.approveDeposits(localId, m.fulfilledAssetAmount);
            target.issueShares(localId, m.fulfilledShareAmount);
            target.fulfillDepositRequest(localId, m.fulfilledAssetAmount, m.fulfilledShareAmount);
        } else if (kind == RequestCallbackType.SettledRedeem) {
            RequestCallbackMessageLib.SettledRedeem memory m = payload.deserializeSettledRedeem();
            IVaultRedeemCallbacks target = IVaultRedeemCallbacks(vault);
            target.revokeShares(localId, m.fulfilledAssetAmount, m.fulfilledShareAmount);
            target.fulfillRedeemRequest(localId, m.fulfilledAssetAmount, m.fulfilledShareAmount);
        } else if (kind == RequestCallbackType.CancelledDeposit) {
            RequestCallbackMessageLib.CancelledDeposit memory m = payload.deserializeCancelledDeposit();
            IVaultDepositCallbacks(vault).cancelDeposit(localId, m.grossAssetAmount, m.netAssetAmount);
        } else if (kind == RequestCallbackType.CancelledRedeem) {
            RequestCallbackMessageLib.CancelledRedeem memory m = payload.deserializeCancelledRedeem();
            IVaultRedeemCallbacks(vault).cancelRedeem(localId, m.grossShareAmount, m.netShareAmount);
        } else {
            revert RequestCallbackMessageLib.UnknownRequestCallbackType();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Outbound requests
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRequestManager
    function sendDepositRequest(uint96 localId, uint128 amount) external {
        _send(localId, amount, true);
    }

    /// @inheritdoc IVaultRequestManager
    function sendRedeemRequest(uint96 localId, uint128 amount) external {
        _send(localId, amount, false);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Position and request id come from the caller, so a vault can neither request outside its
    ///      own position nor forge a sibling's id.
    function _send(uint96 localId, uint128 amount, bool isDeposit) internal {
        VaultDetails memory details = spokeRegistry.vaultDetails(msg.sender);
        require(details.isLinked, NotLinked());
        require(IVault(msg.sender).poolId() == details.poolId, WrongPool());

        RequestId requestId = VaultRequestIdLib.from(msg.sender, localId);
        bytes memory payload = isDeposit
            ? RequestMessageLib.serialize(RequestMessageLib.DepositRequest(requestId, amount))
            : RequestMessageLib.serialize(RequestMessageLib.RedeemRequest(requestId, amount));
        (address refund, uint256 payment) = _subsidy(details);

        spoke.request{value: payment}(
            details.poolId, details.scId, details.assetId, payload, extraGasLimit[details.poolId], true, refund
        );
    }

    /// @dev A same-chain request costs nothing, and a batch's caller funds the requests inside it.
    function _subsidy(VaultDetails memory details) internal returns (address refund, uint256 payment) {
        if (details.poolId.centrifugeId() == details.assetId.centrifugeId() || spoke.gateway().isBatching()) {
            return (address(0), 0);
        }
        return subsidyManager.withdrawAll(details.poolId, address(this));
    }
}

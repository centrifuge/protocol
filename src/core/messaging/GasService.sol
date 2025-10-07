// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "./interfaces/IGasService.sol";
import {IMessageLimits} from "./interfaces/IMessageLimits.sol";
import {GAS_FAIL_MESSAGE_STORAGE} from "./interfaces/IGateway.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "./libraries/MessageLib.sol";

/// @title  GasService
/// @notice This contract stores the gas limits (in gas units) for cross-chain message execution.
///         These values are used by adapters to determine how much gas to allocate for
///         message execution on destination chains.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Takes into account diverge computation from the base menchmarked value.
    /// Also takens into account
    uint128 public constant BASE_COST = 20_000;

    uint128 public immutable scheduleUpgrade;
    uint128 public immutable cancelUpgrade;
    uint128 public immutable recoverTokens;
    uint128 public immutable registerAsset;
    uint128 public immutable setPoolAdapters;
    uint128 public immutable request;
    uint128 public immutable notifyPool;
    uint128 public immutable notifyShareClass;
    uint128 public immutable notifyPricePoolPerShare;
    uint128 public immutable notifyPricePoolPerAsset;
    uint128 public immutable notifyShareMetadata;
    uint128 public immutable updateShareHook;
    uint128 public immutable initiateTransferShares;
    uint128 public immutable executeTransferShares;
    uint128 public immutable updateRestriction;
    uint128 public immutable trustedContractUpdate;
    uint128 public immutable requestCallback;
    uint128 public immutable updateVaultDeployAndLink;
    uint128 public immutable updateVaultLink;
    uint128 public immutable updateVaultUnlink;
    uint128 public immutable setRequestManager;
    uint128 public immutable updateBalanceSheetManager;
    uint128 public immutable updateHoldingAmount;
    uint128 public immutable updateShares;
    uint128 public immutable maxAssetPriceAge;
    uint128 public immutable maxSharePriceAge;
    uint128 public immutable updateGatewayManager;
    uint128 public immutable untrustedContractUpdate;

    constructor() {
        // NOTE: Below values should be updated using script/utils/benchmark.sh
        scheduleUpgrade = _gasValue(93833);
        cancelUpgrade = _gasValue(74240);
        recoverTokens = _gasValue(151038);
        registerAsset = _gasValue(103955);
        setPoolAdapters = _gasValue(481579); // using MAX_ADAPTER_COUNT
        request = _gasValue(220673);
        notifyPool = _gasValue(1150798); // create escrow case
        notifyShareClass = _gasValue(1853009);
        notifyPricePoolPerShare = _gasValue(107070);
        notifyPricePoolPerAsset = _gasValue(111076);
        notifyShareMetadata = _gasValue(121478);
        updateShareHook = _gasValue(96407);
        initiateTransferShares = _gasValue(286613);
        executeTransferShares = _gasValue(177494);
        updateRestriction = _gasValue(114441);
        trustedContractUpdate = _gasValue(142247);
        requestCallback = _gasValue(258482); // approve deposit case
        updateVaultDeployAndLink = _gasValue(2853046);
        updateVaultLink = _gasValue(185355);
        updateVaultUnlink = _gasValue(134073);
        setRequestManager = _gasValue(100900);
        updateBalanceSheetManager = _gasValue(104175);
        updateHoldingAmount = _gasValue(304319);
        updateShares = _gasValue(201531);
        maxAssetPriceAge = _gasValue(110238);
        maxSharePriceAge = _gasValue(107124);
        updateGatewayManager = _gasValue(88420);
        untrustedContractUpdate = _gasValue(83807);
    }

    /// @inheritdoc IMessageLimits
    function messageGasLimit(uint16, bytes calldata message) public view returns (uint128) {
        MessageType kind = message.messageType();

        if (kind == MessageType.ScheduleUpgrade) return scheduleUpgrade;
        if (kind == MessageType.CancelUpgrade) return cancelUpgrade;
        if (kind == MessageType.RecoverTokens) return recoverTokens;
        if (kind == MessageType.RegisterAsset) return registerAsset;
        if (kind == MessageType.SetPoolAdapters) return setPoolAdapters;
        if (kind == MessageType.Request) return request;
        if (kind == MessageType.NotifyPool) return notifyPool;
        if (kind == MessageType.NotifyShareClass) return notifyShareClass;
        if (kind == MessageType.NotifyPricePoolPerShare) return notifyPricePoolPerShare;
        if (kind == MessageType.NotifyPricePoolPerAsset) return notifyPricePoolPerAsset;
        if (kind == MessageType.NotifyShareMetadata) return notifyShareMetadata;
        if (kind == MessageType.UpdateShareHook) return updateShareHook;
        if (kind == MessageType.InitiateTransferShares) return initiateTransferShares;
        if (kind == MessageType.ExecuteTransferShares) return executeTransferShares;
        if (kind == MessageType.UpdateRestriction) return updateRestriction;
        if (kind == MessageType.TrustedContractUpdate) return trustedContractUpdate;
        if (kind == MessageType.RequestCallback) return requestCallback;
        if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);
            if (vaultKind == VaultUpdateKind.DeployAndLink) return updateVaultDeployAndLink;
            if (vaultKind == VaultUpdateKind.Link) return updateVaultLink;
            if (vaultKind == VaultUpdateKind.Unlink) return updateVaultUnlink;
            revert InvalidMessageType(); // Unreachable
        }
        if (kind == MessageType.SetRequestManager) return setRequestManager;
        if (kind == MessageType.UpdateBalanceSheetManager) return updateBalanceSheetManager;
        if (kind == MessageType.UpdateHoldingAmount) return updateHoldingAmount;
        if (kind == MessageType.UpdateShares) return updateShares;
        if (kind == MessageType.MaxAssetPriceAge) return maxAssetPriceAge;
        if (kind == MessageType.MaxSharePriceAge) return maxSharePriceAge;
        if (kind == MessageType.UpdateGatewayManager) return updateGatewayManager;
        if (kind == MessageType.UntrustedContractUpdate) return untrustedContractUpdate;
        revert InvalidMessageType(); // Unreachable
    }

    /// @dev - BASE_COST adds some offset to the benchmarked message
    ///      - GAS_FAIL_MESSAGE_STORAGE is an extra required to process a possible message failure
    ///      - Multiply by 64/63 is because EIP-150 pass 63/64 gas to each method call,
    ///        so we add here the adapter call required gas.
    function _gasValue(uint128 value) internal pure returns (uint128) {
        return BASE_COST + uint128(GAS_FAIL_MESSAGE_STORAGE) + 64 * value / 63;
    }
}

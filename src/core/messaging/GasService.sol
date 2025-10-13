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
        scheduleUpgrade = _gasValue(93006);
        cancelUpgrade = _gasValue(73413);
        recoverTokens = _gasValue(150211);
        registerAsset = _gasValue(103128);
        setPoolAdapters = _gasValue(480752); // using MAX_ADAPTER_COUNT
        request = _gasValue(224310);
        notifyPool = _gasValue(1139136); // create escrow case
        notifyShareClass = _gasValue(1841554);
        notifyPricePoolPerShare = _gasValue(106243);
        notifyPricePoolPerAsset = _gasValue(110249);
        notifyShareMetadata = _gasValue(120651);
        updateShareHook = _gasValue(95580);
        initiateTransferShares = _gasValue(285786);
        executeTransferShares = _gasValue(176667);
        updateRestriction = _gasValue(113614);
        trustedContractUpdate = _gasValue(141395);
        requestCallback = _gasValue(262127); // approve deposit case
        updateVaultDeployAndLink = _gasValue(2841589);
        updateVaultLink = _gasValue(184528);
        updateVaultUnlink = _gasValue(133246);
        setRequestManager = _gasValue(104617);
        updateBalanceSheetManager = _gasValue(103348);
        updateHoldingAmount = _gasValue(303492);
        updateShares = _gasValue(200704);
        maxAssetPriceAge = _gasValue(109411);
        maxSharePriceAge = _gasValue(106297);
        updateGatewayManager = _gasValue(92137);
        untrustedContractUpdate = _gasValue(87524);
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "./interfaces/IGasService.sol";
import {IMessageLimits} from "./interfaces/IMessageLimits.sol";
import {PROCESS_FAIL_MESSAGE_GAS} from "./interfaces/IGateway.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "./libraries/MessageLib.sol";

/// @title  GasService
/// @notice This contract stores the gas limits (in gas units) for cross-chain message execution.
///         These values are used by adapters to determine how much gas to allocate for
///         message execution on destination chains.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Takes into account diverge computation from the base benchmarked value.
    uint128 public constant BASE_COST = 100_000;

    /// @dev Adds an extra cost to recover token admin message to ensure different assets can transfer successfully
    uint128 public constant RECOVERY_TOKEN_EXTRA_COST = 100_000;

    uint128 public constant MIN_SUPPORTED_BLOCK_LIMIT = 24; // In millions of gas units

    /// @dev An encoded array of the block limits of the first 32 centrifugeId.
    ///      Measured in millions of gas units
    uint256 public immutable blockLimitsPerCentrifugeId;

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

    constructor(uint8[32] memory blockLimits) {
        for (uint256 i; i < blockLimits.length; i++) {
            uint256 value = blockLimits[i] > 0 ? blockLimits[i] : MIN_SUPPORTED_BLOCK_LIMIT;
            blockLimitsPerCentrifugeId += value << (31 - i) * 8;
        }

        // NOTE: Below values should be updated using script/utils/benchmark.sh
        scheduleUpgrade = _gasValue(95182);
        cancelUpgrade = _gasValue(75589);
        recoverTokens = RECOVERY_TOKEN_EXTRA_COST + _gasValue(152238);
        registerAsset = _gasValue(104983);
        setPoolAdapters = _gasValue(488111); // using MAX_ADAPTER_COUNT
        request = _gasValue(221767);
        notifyPool = _gasValue(1156414); // create escrow case
        notifyShareClass = _gasValue(1860770);
        notifyPricePoolPerShare = _gasValue(103070);
        notifyPricePoolPerAsset = _gasValue(107088);
        notifyShareMetadata = _gasValue(117547);
        updateShareHook = _gasValue(92450);
        initiateTransferShares = _gasValue(282380);
        executeTransferShares = _gasValue(173529);
        updateRestriction = _gasValue(110680);
        trustedContractUpdate = _gasValue(137255);
        requestCallback = _gasValue(257541); // approve deposit case
        updateVaultDeployAndLink = _gasValue(2839851);
        updateVaultLink = _gasValue(181379);
        updateVaultUnlink = _gasValue(130097);
        setRequestManager = _gasValue(101444);
        updateBalanceSheetManager = _gasValue(100218);
        updateHoldingAmount = _gasValue(300614);
        updateShares = _gasValue(197700);
        maxAssetPriceAge = _gasValue(106282);
        maxSharePriceAge = _gasValue(103167);
        updateGatewayManager = _gasValue(97719);
        untrustedContractUpdate = _gasValue(84977);
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
        if (kind == MessageType.SetMaxAssetPriceAge) return maxAssetPriceAge;
        if (kind == MessageType.SetMaxSharePriceAge) return maxSharePriceAge;
        if (kind == MessageType.UpdateGatewayManager) return updateGatewayManager;
        if (kind == MessageType.UntrustedContractUpdate) return untrustedContractUpdate;
        revert InvalidMessageType(); // Unreachable
    }

    /// @inheritdoc IMessageLimits
    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128) {
        // blockLimitsPerCentrifugeId counts millions of gas units, then we need to multiply by 1_000_000
        // The final result is multiplied by 0.75 to avoid having a transaction that can occupy the entire block
        return (centrifugeId < 32
                    ? uint8(bytes32(blockLimitsPerCentrifugeId)[centrifugeId])
                    : MIN_SUPPORTED_BLOCK_LIMIT) * 1_000_000 * 3 / 4;
    }

    /// @dev - BASE_COST adds some offset to the benchmarked message
    ///      - PROCESS_FAIL_MESSAGE_GAS is an extra required to process a possible message failure
    ///      - Multiply by 64/63 is because EIP-150 pass 63/64 gas to each method call,
    ///        so we add here the adapter call required gas.
    function _gasValue(uint128 value) internal pure returns (uint128) {
        return BASE_COST + uint128(PROCESS_FAIL_MESSAGE_GAS) + 64 * value / 63;
    }
}

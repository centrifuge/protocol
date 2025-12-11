// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "./interfaces/IGasService.sol";
import {PROCESS_FAIL_MESSAGE_GAS} from "./interfaces/IGateway.sol";
import {IMessageProperties} from "./interfaces/IMessageProperties.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "./libraries/MessageLib.sol";

import {PoolId} from "../types/PoolId.sol";

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

    uint128 public constant DEFAULT_SUPPORTED_TX_LIMIT = 10; // In millions of gas units

    /// @dev An encoded array of the block limits of the first 32 centrifugeId.
    ///      Measured in millions of gas units
    uint256 public immutable txLimitsPerCentrifugeId;

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

    constructor(uint8[32] memory txLimits) {
        for (uint256 i; i < txLimits.length; i++) {
            uint256 value = txLimits[i] > 0 ? txLimits[i] : DEFAULT_SUPPORTED_TX_LIMIT;
            txLimitsPerCentrifugeId += value << (31 - i) * 8;
        }

        // NOTE: Below values should be updated using script/utils/benchmark.sh
        scheduleUpgrade = _gasValue(93958);
        cancelUpgrade = _gasValue(74414);
        recoverTokens = RECOVERY_TOKEN_EXTRA_COST + _gasValue(150077);
        registerAsset = _gasValue(104159);
        setPoolAdapters = _gasValue(484969); // using MAX_ADAPTER_COUNT
        request = _gasValue(217980);
        notifyPool = _gasValue(1303809); // create escrow case
        notifyShareClass = _gasValue(1858394);
        notifyPricePoolPerShare = _gasValue(102238);
        notifyPricePoolPerAsset = _gasValue(106051);
        notifyShareMetadata = _gasValue(115801);
        updateShareHook = _gasValue(91765);
        initiateTransferShares = _gasValue(282064);
        executeTransferShares = _gasValue(172874);
        updateRestriction = _gasValue(112674);
        trustedContractUpdate = _gasValue(144097);
        requestCallback = _gasValue(309589); // approve deposit case
        updateVaultDeployAndLink = _gasValue(2841256);
        updateVaultLink = _gasValue(182899);
        updateVaultUnlink = _gasValue(131666);
        setRequestManager = _gasValue(101102);
        updateBalanceSheetManager = _gasValue(99881);
        updateHoldingAmount = _gasValue(300858);
        updateShares = _gasValue(198275);
        maxAssetPriceAge = _gasValue(106136);
        maxSharePriceAge = _gasValue(103070);
        updateGatewayManager = _gasValue(97649);
        untrustedContractUpdate = _gasValue(85090);
    }

    /// @inheritdoc IMessageProperties
    function messageOverallGasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        return messageProcessingGasLimit(centrifugeId, message) + BASE_COST;
    }

    /// @inheritdoc IMessageProperties
    function messageProcessingGasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        return _messageBaseGasLimit(centrifugeId, message) + message.messageExtraGasLimit();
    }

    function _messageBaseGasLimit(uint16, bytes calldata message) internal view returns (uint128) {
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

    /// @inheritdoc IMessageProperties
    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128) {
        // txLimitsPerCentrifugeId counts millions of gas units, then we need to multiply by 1_000_000
        return (centrifugeId < 32 ? uint8(bytes32(txLimitsPerCentrifugeId)[centrifugeId]) : DEFAULT_SUPPORTED_TX_LIMIT)
            * 1_000_000;
    }

    /// @inheritdoc IMessageProperties
    function messageLength(bytes calldata message) external pure returns (uint16) {
        return message.messageLength();
    }

    /// @inheritdoc IMessageProperties
    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        return message.messagePoolId();
    }

    /// @dev - BASE_COST adds some offset to the benchmarked message
    ///      - PROCESS_FAIL_MESSAGE_GAS is an extra required to process a possible message failure
    ///      - Multiply by 64/63 is because EIP-150 pass 63/64 gas to each method call,
    ///        so we add here the adapter call required gas.
    function _gasValue(uint128 value) internal pure returns (uint128) {
        return uint128(PROCESS_FAIL_MESSAGE_GAS) + 64 * value / 63;
    }
}

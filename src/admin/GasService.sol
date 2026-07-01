// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "./interfaces/IGasService.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {IMessageProperties} from "../core/messaging/interfaces/IMessageProperties.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "../core/messaging/libraries/MessageLib.sol";

/// @title  GasService
/// @notice Stores per-message-type gas costs (in gas units) for cross-chain execution.
///         Each immutable holds the raw benchmarked execution cost. The failure gas reserve
///         for the destination chain is added on top at query time by messageProcessingGasLimit,
///         so a single deployment correctly provisions gas for all connected chains.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Covers the real adapter overhead (Axelar/LZ signature verification and relay execution)
    ///      that occurs before MultiAdapter.handle() is called on the destination chain.
    ///      LocalAdapter used in tests is a trivial passthrough, so this cost is not captured by the benchmark.
    uint128 public constant BASE_ADAPTER_COST = 75_000;

    uint128 public constant DEFAULT_SUPPORTED_TX_LIMIT = 10; // In millions of gas units

    // NOTE: This value should be benchmarked via test/integration/GatewayFailGas.t.sol
    uint128 public constant DEFAULT_FAILURE_GAS_RESERVE = 35_000;

    // NOTE: Monad reprices cold CALL (2600→10100) and cold SSTORE access (2100→8100),
    // adding ~13500 gas to the failure path. This value is an estimate until Foundry's
    // gas tooling supports Monad-specific opcode pricing.
    uint16 public constant MONAD_CENTRIFUGE_ID = 11;
    uint128 public constant MONAD_FAILURE_GAS_RESERVE = 47_000;

    /// @inheritdoc IMessageProperties
    uint128 public immutable messageFailureGasReserve;

    /// @dev An encoded array of the block limits of the first 32 centrifugeId.
    ///      Measured in millions of gas units
    uint256 public immutable txLimitsPerCentrifugeId;

    uint128 public immutable scheduleUpgrade;
    uint128 public immutable cancelUpgrade;
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
    uint128 public immutable managerCall;
    uint128 public immutable requestCallback;
    uint128 public immutable updateVaultDeployAndLink;
    uint128 public immutable updateVaultLink;
    uint128 public immutable updateVaultUnlink;
    uint128 public immutable setRequestManager;
    uint128 public immutable updateManager;
    uint128 public immutable updateHoldingAmount;
    uint128 public immutable updateShares;
    uint128 public immutable maxAssetPriceAge;
    uint128 public immutable maxSharePriceAge;
    uint128 public immutable untrustedContractUpdate;

    constructor(uint8[32] memory txLimits, uint16 localCentrifugeId_) {
        messageFailureGasReserve = _chainFailureReserve(localCentrifugeId_);

        for (uint256 i; i < txLimits.length; i++) {
            uint256 value = txLimits[i] > 0 ? txLimits[i] : DEFAULT_SUPPORTED_TX_LIMIT;
            txLimitsPerCentrifugeId += value << (31 - i) * 8;
        }

        scheduleUpgrade = _gasValue(152515);
        cancelUpgrade = _gasValue(132971);
        registerAsset = _gasValue(162609);
        setPoolAdapters = _gasValue(781322); // using MAX_ADAPTER_COUNT
        request = _gasValue(275913);
        notifyPool = _gasValue(1340225); // create escrow case
        notifyShareClass = _gasValue(1917998);
        notifyPricePoolPerShare = _gasValue(161750);
        notifyPricePoolPerAsset = _gasValue(165580);
        notifyShareMetadata = _gasValue(175374);
        updateShareHook = _gasValue(151278);
        initiateTransferShares = _gasValue(340789);
        executeTransferShares = _gasValue(232402);
        updateRestriction = _gasValue(172203);
        managerCall = _gasValue(219162);
        requestCallback = _gasValue(448920); // approve deposit case
        updateVaultDeployAndLink = _gasValue(2900785);
        updateVaultLink = _gasValue(242428);
        updateVaultUnlink = _gasValue(191195);
        setRequestManager = _gasValue(160614);
        updateManager = _gasValue(159830);
        updateHoldingAmount = _gasValue(359959);
        updateShares = _gasValue(257088);
        maxAssetPriceAge = _gasValue(165648);
        maxSharePriceAge = _gasValue(162583);
        untrustedContractUpdate = _gasValue(143941);
    }

    /// @inheritdoc IMessageProperties
    function messageOverallGasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        uint128 value = messageProcessingGasLimit(centrifugeId, message) + BASE_ADAPTER_COST;
        // Multiply by 64/63 is because EIP-150 pass 63/64 gas to each method call
        // Calls from adapters requires adding more jumps (3): Executor -> Adapter -> MultiAdapter -> Gateway.
        return value * 262144 / 250047; // Equivalent to: value * 64 * 64 * 64 / (63 * 63 * 63)
    }

    /// @inheritdoc IMessageProperties
    /// @dev No 64/63 correction needed: benchmarks are taken at the same call depth this is invoked.
    ///      Adds _chainFailureReserve(centrifugeId) so the destination Gateway always has enough gas
    ///      to record a processor revert regardless of which chain is executing the message.
    function messageProcessingGasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        return _messageBaseGasLimit(message) + message.messageExtraGasLimit() + _chainFailureReserve(centrifugeId);
    }

    /// @dev Returns the gas that Gateway._safeProcess must withhold from the inner call on the given chain
    ///      to guarantee the failure path (failedMessages write + FailMessage event) can always complete.
    ///      Chains with non-standard opcode pricing get a dedicated constant; all others use the default.
    function _chainFailureReserve(uint16 centrifugeId) internal pure returns (uint128) {
        if (centrifugeId == MONAD_CENTRIFUGE_ID) return MONAD_FAILURE_GAS_RESERVE;
        return DEFAULT_FAILURE_GAS_RESERVE;
    }

    function _messageBaseGasLimit(bytes calldata message) internal view returns (uint128) {
        MessageType kind = message.messageType();

        if (kind == MessageType.ScheduleUpgrade) return scheduleUpgrade;
        if (kind == MessageType.CancelUpgrade) return cancelUpgrade;
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
        if (kind == MessageType.ManagerCall) return managerCall;
        if (kind == MessageType.RequestCallback) return requestCallback;
        if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);
            if (vaultKind == VaultUpdateKind.DeployAndLink) return updateVaultDeployAndLink;
            if (vaultKind == VaultUpdateKind.Link) return updateVaultLink;
            if (vaultKind == VaultUpdateKind.Unlink) return updateVaultUnlink;
            return 100_000; // Some high value just to compute the call and fail inside the Gateway try/catch
        }
        if (kind == MessageType.SetRequestManager) return setRequestManager;
        if (kind == MessageType.UpdateManager) return updateManager;
        if (kind == MessageType.UpdateHoldingAmount) return updateHoldingAmount;
        if (kind == MessageType.UpdateShares) return updateShares;
        if (kind == MessageType.SetMaxAssetPriceAge) return maxAssetPriceAge;
        if (kind == MessageType.SetMaxSharePriceAge) return maxSharePriceAge;
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

    /// @inheritdoc IMessageProperties
    function routePoolId(bytes calldata message, bool poolConfigured) external pure returns (PoolId) {
        return message.routePoolId(poolConfigured);
    }

    function _gasValue(uint128 value) internal pure returns (uint128) {
        return value;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService, IAdapterGasService} from "./interfaces/IGasService.sol";

import {IMessageGas} from "../core/messaging/interfaces/IMessageGas.sol";
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

    // NOTE: Monad reprices cold account access (2600→10100) and cold storage access (2100→8100), so the
    // failure path's 1 cold SSTORE (failedMessages) + 1 cold CALL (processor, charged to the frame the
    // reserve protects) costs +13_500. Estimate until Foundry's gas tooling prices Monad opcodes.
    uint16 public constant MONAD_CENTRIFUGE_ID = 11;
    uint128 public constant MONAD_FAILURE_GAS_RESERVE = DEFAULT_FAILURE_GAS_RESERVE + 13_500;

    // Monad's cold-access repricing over Ethereum, charged per distinct slot/account a handler touches.
    uint128 public constant MONAD_COLD_SLOT_SURCHARGE = 6000;
    uint128 public constant MONAD_COLD_ACCOUNT_SURCHARGE = 7500;

    // What an adapter's own receive path, up to the entrypoint.handle() it wraps, costs on the schedule
    // the benchmarks were taken on, and the cold accesses it makes. Held here rather than in the adapter
    // so that rebenchmarking one, or pricing it for a chain that reprices access, is a change to this
    // contract: adapters are deployed per network and rewired per pool, this is replaced every release.
    uint128 public constant AXELAR_RECEIVE_COST = 26_000;
    uint128 public constant CHAINLINK_RECEIVE_COST = 10_000;
    uint128 public constant HYPERLANE_RECEIVE_COST = 10_000;
    uint128 public constant LAYER_ZERO_RECEIVE_COST = 10_000;
    uint128 public constant STANDBY_RECEIVE_COST = 3_500;

    /// @dev One entry per benchmarked message: every MessageType, then UpdateVault's three VaultUpdateKind
    ///      variants from UPDATE_VAULT_COUNT_OFFSET on, which leaves UpdateVault's own index unused.
    ///      Kept a literal because solc rejects a derived expression as an array length, so a stale value
    ///      fails to compile against the generated count literals instead of silently misreading them.
    uint256 internal constant COLD_COUNT_ENTRIES = 28;
    uint256 internal constant UPDATE_VAULT_COUNT_OFFSET = uint256(uint8(type(MessageType).max)) + 1;

    /// @inheritdoc IMessageGas
    uint128 public immutable messageFailureGasReserve;

    /// @dev An encoded array of the block limits of the first 32 centrifugeId.
    ///      Measured in millions of gas units
    uint256 public immutable txLimitsPerCentrifugeId;

    /// @dev Distinct storage slots and accounts a handler first touches, one byte per benchmarked message.
    ///      Benchmarks run against warm state and so never pay for these, which is why chains that
    ///      reprice cold access need them counted separately.
    uint256 public immutable coldSlotsPerMessageType;
    uint256 public immutable coldAccountsPerMessageType;

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
    uint128 public immutable initiateTransferShares;
    uint128 public immutable executeTransferShares;
    uint128 public immutable updateRestriction;
    uint128 public immutable managerCallFromHub;
    uint128 public immutable requestCallback;
    uint128 public immutable updateVaultDeployAndLink;
    uint128 public immutable updateVaultLink;
    uint128 public immutable updateVaultUnlink;
    uint128 public immutable setRequestManager;
    uint128 public immutable setPolicy;
    uint128 public immutable authorizeSpokeCall;
    uint128 public immutable unauthorizeSpokeCall;
    uint128 public immutable updateManager;
    uint128 public immutable updateAssets;
    uint128 public immutable updateShares;
    uint128 public immutable managerCallFromSpoke;

    constructor(uint8[32] memory txLimits, uint16 localCentrifugeId_) {
        messageFailureGasReserve = _chainFailureReserve(localCentrifugeId_);

        for (uint256 i; i < txLimits.length; i++) {
            uint256 value = txLimits[i] > 0 ? txLimits[i] : DEFAULT_SUPPORTED_TX_LIMIT;
            txLimitsPerCentrifugeId += value << (31 - i) * 8;
        }

        // forgefmt: disable-next-item
        coldSlotsPerMessageType = _pack(
            [uint8(0), 14, 13, 15, 40, 23, 24, 17, 19, 20, 39, 23, 23, 0, 36, 24, 29, 41, 17, 13, 29, 17, 17, 17, 17, 35, 21, 20]
        );
        coldAccountsPerMessageType = _pack(
            [uint8(0), 7, 7, 9, 7, 11, 11, 9, 9, 11, 18, 12, 13, 0, 14, 11, 12, 17, 9, 9, 15, 9, 9, 9, 9, 14, 9, 9]
        );

        scheduleUpgrade = _gasValue(161033);
        cancelUpgrade = _gasValue(141526);
        registerAsset = _gasValue(168164);
        setPoolAdapters = _gasValue(790115); // using MAX_ADAPTER_COUNT
        request = _gasValue(281382);
        notifyPool = _gasValue(1378159);
        notifyShareClass = _gasValue(1874967);
        notifyPricePoolPerShare = _gasValue(176749);
        notifyPricePoolPerAsset = _gasValue(183284);
        notifyShareMetadata = _gasValue(198851);
        initiateTransferShares = _gasValue(382494);
        executeTransferShares = _gasValue(253673);
        updateRestriction = _gasValue(212813);
        managerCallFromHub = _gasValue(377978);
        requestCallback = _gasValue(463976); // approve deposit case
        updateVaultDeployAndLink = _gasValue(2868928);
        updateVaultLink = _gasValue(191174);
        updateVaultUnlink = _gasValue(171934);
        setRequestManager = _gasValue(175521);
        setPolicy = _gasValue(176573);
        authorizeSpokeCall = _gasValue(183638);
        unauthorizeSpokeCall = _gasValue(161299);
        updateManager = _gasValue(177720);
        updateAssets = _gasValue(393124);
        updateShares = _gasValue(266397);
        managerCallFromSpoke = _gasValue(150344);
    }

    /// @inheritdoc IMessageGas
    function messageOverallGasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        uint128 value = messageProcessingGasLimit(centrifugeId, message) + BASE_ADAPTER_COST;
        // Multiply by 64/63 is because EIP-150 pass 63/64 gas to each method call
        // Calls from adapters requires adding more jumps (3): Executor -> Adapter -> MultiAdapter -> Gateway.
        return value * 262144 / 250047; // Equivalent to: value * 64 * 64 * 64 / (63 * 63 * 63)
    }

    /// @inheritdoc IMessageGas
    /// @dev No 64/63 correction needed: benchmarks are taken at the same call depth this is invoked.
    ///      Adds _chainFailureReserve(centrifugeId) so the destination Gateway always has enough gas
    ///      to record a processor revert regardless of which chain is executing the message.
    function messageProcessingGasLimit(uint16 centrifugeId, bytes calldata message) public view returns (uint128) {
        return _messageBaseGasLimit(message) + message.messageExtraGasLimit() + _chainFailureReserve(centrifugeId)
            + _chainColdAccessSurcharge(centrifugeId, message);
    }

    /// @dev Returns the gas that Gateway._safeProcess must withhold from the inner call on the given chain
    ///      to guarantee the failure path (failedMessages write + FailMessage event) can always complete.
    ///      Chains with non-standard opcode pricing get a dedicated constant; all others use the default.
    function _chainFailureReserve(uint16 centrifugeId) internal pure returns (uint128) {
        if (centrifugeId == MONAD_CENTRIFUGE_ID) return MONAD_FAILURE_GAS_RESERVE;
        return DEFAULT_FAILURE_GAS_RESERVE;
    }

    /// @dev On chains that reprice cold access, the benchmarked limit is short by the repricing delta on
    ///      every slot and account the handler first touches, since the benchmark runs against warm state.
    ///      Resolves UpdateVault to its VaultUpdateKind, whose variants differ by ~15 slots.
    function _chainColdAccessSurcharge(uint16 centrifugeId, bytes calldata message) internal view returns (uint128) {
        if (centrifugeId != MONAD_CENTRIFUGE_ID) return 0;

        MessageType kind = message.messageType();
        uint256 index = kind == MessageType.UpdateVault
            ? UPDATE_VAULT_COUNT_OFFSET + uint256(message.deserializeUpdateVault().kind)
            : uint256(uint8(kind));

        return _coldAccessSurcharge(
            centrifugeId,
            uint8(bytes32(coldSlotsPerMessageType)[index]),
            uint8(bytes32(coldAccountsPerMessageType)[index])
        );
    }

    /// @dev The benchmarked chain is the reference and pays nothing; chains that reprice cold access pay
    ///      the delta per slot and per account.
    function _coldAccessSurcharge(uint16 centrifugeId, uint128 slots, uint128 accounts)
        internal
        pure
        returns (uint128)
    {
        if (centrifugeId != MONAD_CENTRIFUGE_ID) return 0;
        return slots * MONAD_COLD_SLOT_SURCHARGE + accounts * MONAD_COLD_ACCOUNT_SURCHARGE;
    }

    function _pack(uint8[COLD_COUNT_ENTRIES] memory counts) internal pure returns (uint256 packed) {
        for (uint256 i; i < counts.length; i++) {
            packed += uint256(counts[i]) << (31 - i) * 8;
        }
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
        if (kind == MessageType.InitiateTransferShares) return initiateTransferShares;
        if (kind == MessageType.ExecuteTransferShares) return executeTransferShares;
        if (kind == MessageType.UpdateRestriction) return updateRestriction;
        if (kind == MessageType.ManagerCallFromHub) return managerCallFromHub;
        if (kind == MessageType.RequestCallback) return requestCallback;
        if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);
            if (vaultKind == VaultUpdateKind.DeployAndLink) return updateVaultDeployAndLink;
            if (vaultKind == VaultUpdateKind.Link) return updateVaultLink;
            if (vaultKind == VaultUpdateKind.Unlink) return updateVaultUnlink;
            return 100_000; // Some high value just to compute the call and fail inside the Gateway try/catch
        }
        if (kind == MessageType.SetRequestManager) return setRequestManager;
        if (kind == MessageType.SetPolicy) return setPolicy;
        if (kind == MessageType.AuthorizeSpokeCall) return authorizeSpokeCall;
        if (kind == MessageType.UnauthorizeSpokeCall) return unauthorizeSpokeCall;
        if (kind == MessageType.UpdateManager) return updateManager;
        if (kind == MessageType.UpdateAssets) return updateAssets;
        if (kind == MessageType.UpdateShares) return updateShares;
        if (kind == MessageType.ManagerCallFromSpoke) return managerCallFromSpoke;
        revert InvalidMessageType(); // Unreachable
    }

    /// @inheritdoc IAdapterGasService
    function receiveCost(uint16 centrifugeId, bytes32 adapter) external pure returns (uint128) {
        (uint128 baseCost, uint128 coldSlots, uint128 coldAccounts) = _adapterProfile(adapter);
        return baseCost + _coldAccessSurcharge(centrifugeId, coldSlots, coldAccounts);
    }

    /// @dev What each adapter's receive path costs on the benchmarked schedule, and what it first touches.
    ///      Axelar: 2 cold SLOADs (`sources`, a uint16 and a bytes32 over two slots) + 2 cold CALLs
    ///      (validateContractCall, entrypoint). The gateway's own cold writes are not reserved, so this
    ///      may be low. Tested in production against the real validateContractCall.
    ///      Chainlink, Hyperlane, LayerZero: 1 cold SLOAD (`sources`) + 1 cold CALL (entrypoint) at 4_700,
    ///      plus a flat 5_300 for dispatch, calldata decode, mapping hash, memory and call setup.
    ///      Standby: 1 cold CALL (entrypoint) at 2_600, plus a flat 900 for dispatch, calldata copy and
    ///      call setup. Measured at ~3_000 relaying a 1KB message.
    function _adapterProfile(bytes32 adapter)
        internal
        pure
        returns (uint128 baseCost, uint128 coldSlots, uint128 coldAccounts)
    {
        if (adapter == "axelar") return (AXELAR_RECEIVE_COST, 2, 2);
        if (adapter == "chainlink") return (CHAINLINK_RECEIVE_COST, 1, 1);
        if (adapter == "hyperlane") return (HYPERLANE_RECEIVE_COST, 1, 1);
        if (adapter == "layerZero") return (LAYER_ZERO_RECEIVE_COST, 1, 1);
        if (adapter == "standby") return (STANDBY_RECEIVE_COST, 0, 1);
        revert UnknownAdapter();
    }

    /// @inheritdoc IMessageGas
    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128) {
        // txLimitsPerCentrifugeId counts millions of gas units, then we need to multiply by 1_000_000
        return (centrifugeId < 32 ? uint8(bytes32(txLimitsPerCentrifugeId)[centrifugeId]) : DEFAULT_SUPPORTED_TX_LIMIT)
            * 1_000_000;
    }

    function _gasValue(uint128 value) internal pure returns (uint128) {
        return value;
    }
}

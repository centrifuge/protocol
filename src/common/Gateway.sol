// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IGasService} from "./interfaces/IGasService.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IMessageProcessor} from "./interfaces/IMessageProcessor.sol";

import {Auth} from "../misc/Auth.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {TransientArrayLib} from "../misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "../misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "../misc/libraries/TransientStorageLib.sol";
import {Recoverable, IRecoverable, ETH_ADDRESS} from "../misc/Recoverable.sol";

/// @title  Gateway
/// @notice Routing contract that forwards outgoing messages through an adapter
///
///         Supports batching multiple messages, as well as paying for methods manually or through pool-level subsidies.
///
///         Supports processing multiple duplicate messages in parallel by storing counts of messages
///         that have been received. Also implements a retry method for failed messages.
contract Gateway is Auth, Recoverable, IGateway {
    using MathLib for *;
    using BytesLib for bytes;
    using TransientStorageLib for bytes32;

    PoolId public constant GLOBAL_POT = PoolId.wrap(0);
    uint256 public constant GAS_FAIL_MESSAGE_STORAGE = 40_000; // check testMessageFailBenchmark
    bytes32 public constant BATCH_LOCATORS_SLOT = bytes32(uint256(keccak256("Centrifuge/batch-locators")) - 1);

    uint16 public immutable localCentrifugeId;

    // Dependencies
    IRoot public immutable root;
    IGasService public gasService;
    IMessageProcessor public processor;
    IAdapter public adapter;

    // Management
    mapping(PoolId => mapping(address => bool)) public manager;

    // Outbound & payments
    bool public transient isBatching;
    mapping(PoolId => Funds) public subsidy;
    mapping(uint16 centrifugeId => mapping(PoolId => bool)) public isOutgoingBlocked;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => Underpaid)) public underpaid;

    // Inbound
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => uint256)) public failedMessages;

    constructor(uint16 localCentrifugeId_, IRoot root_, IGasService gasService_, address deployer) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        root = root_;
        gasService = gasService_;

        subsidy[GLOBAL_POT].refund = IRecoverable(address(this));
        emit SetRefundAddress(GLOBAL_POT, IRecoverable(address(this)));
    }

    modifier pauseable() {
        require(!root.paused(), Paused());
        _;
    }

    modifier onlyAuthOrManager(PoolId poolId) {
        require(wards[msg.sender] == 1 || manager[poolId][msg.sender], NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function file(bytes32 what, address instance) external auth {
        if (what == "gasService") gasService = IGasService(instance);
        else if (what == "processor") processor = IMessageProcessor(instance);
        else if (what == "adapter") adapter = IAdapter(instance);
        else revert FileUnrecognizedParam();

        emit File(what, instance);
    }

    /// @inheritdoc IGateway
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    receive() external payable {
        _depositSubsidy(GLOBAL_POT, msg.sender, msg.value);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes memory batch) public pauseable auth {
        bytes memory remaining = batch;

        while (remaining.length > 0) {
            uint256 length = processor.messageLength(remaining);
            bytes memory message = remaining.slice(0, length);
            remaining = remaining.slice(length, remaining.length - length);

            uint256 executionGas = gasService.messageGasLimit(localCentrifugeId, message);
            require(gasleft() >= executionGas + GAS_FAIL_MESSAGE_STORAGE, NotEnoughGasToProcess());

            _process(centrifugeId, message, keccak256(message));
        }
    }

    function _process(uint16 centrifugeId, bytes memory message, bytes32 messageHash) internal {
        try processor.handle{gas: gasleft() - GAS_FAIL_MESSAGE_STORAGE}(centrifugeId, message) {
            emit ExecuteMessage(centrifugeId, message, messageHash);
        } catch (bytes memory err) {
            failedMessages[centrifugeId][messageHash]++;
            emit FailMessage(centrifugeId, message, messageHash, err);
        }
    }

    /// @inheritdoc IGateway
    function retry(uint16 centrifugeId, bytes memory message) external pauseable {
        bytes32 messageHash = keccak256(message);
        require(failedMessages[centrifugeId][messageHash] > 0, NotFailedMessage());

        failedMessages[centrifugeId][messageHash]--;
        processor.handle(centrifugeId, message);

        emit ExecuteMessage(centrifugeId, message, messageHash);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function send(uint16 centrifugeId, bytes calldata message, uint128 extraGasLimit)
        external
        pauseable
        auth
        returns (uint256)
    {
        require(message.length > 0, EmptyMessage());

        PoolId poolId = processor.messagePoolId(message);

        emit PrepareMessage(centrifugeId, poolId, message);

        uint128 gasLimit = gasService.messageGasLimit(centrifugeId, message) + extraGasLimit;

        if (isBatching) {
            bytes32 batchSlot = _outboundBatchSlot(centrifugeId, poolId);
            bytes memory previousMessage = TransientBytesLib.get(batchSlot);

            bytes32 gasLimitSlot = _gasLimitSlot(centrifugeId, poolId);
            uint128 newGasLimit = gasLimitSlot.tloadUint128() + gasLimit;
            require(newGasLimit <= gasService.maxBatchGasLimit(centrifugeId), ExceedsMaxGasLimit());
            gasLimitSlot.tstore(uint256(newGasLimit));

            if (previousMessage.length == 0) {
                TransientArrayLib.push(BATCH_LOCATORS_SLOT, _encodeLocator(centrifugeId, poolId));
            }

            TransientBytesLib.append(batchSlot, message);
            return 0;
        } else {
            return _send(centrifugeId, message, gasLimit);
        }
    }

    function _send(uint16 centrifugeId, bytes memory batch, uint128 batchGasLimit) internal returns (uint256) {
        PoolId adapterPoolId = processor.messagePoolId(batch);
        require(!isOutgoingBlocked[centrifugeId][adapterPoolId], OutgoingBlocked());

        PoolId paymentPoolId = processor.messagePoolIdPayment(batch);
        uint256 cost = adapter.estimate(centrifugeId, batch, batchGasLimit);

        if (cost > subsidy[paymentPoolId].value) _requestPoolFunding(paymentPoolId);

        if (cost <= subsidy[paymentPoolId].value) {
            subsidy[paymentPoolId].value -= cost.toUint96();
        } else {
            _addUnpaidBatch(centrifugeId, batch, batchGasLimit);
            return 0;
        }

        adapter.send{value: cost}(centrifugeId, batch, batchGasLimit, address(subsidy[paymentPoolId].refund));

        return cost;
    }

    /// @inheritdoc IGateway
    function addUnpaidMessage(uint16 centrifugeId, bytes memory message, uint128 extraGasLimit) external auth {
        uint128 gasLimit = gasService.messageGasLimit(centrifugeId, message) + extraGasLimit;
        emit PrepareMessage(centrifugeId, processor.messagePoolId(message), message);
        _addUnpaidBatch(centrifugeId, message, gasLimit);
    }

    function _addUnpaidBatch(uint16 centrifugeId, bytes memory message, uint128 gasLimit) internal {
        bytes32 batchHash = keccak256(message);

        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        underpaid_.counter++;
        underpaid_.gasLimit = gasLimit;

        emit UnderpaidBatch(centrifugeId, message, batchHash);
    }

    /// @inheritdoc IGateway
    function repay(uint16 centrifugeId, bytes memory batch) external payable pauseable {
        bytes32 batchHash = keccak256(batch);
        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        require(underpaid_.counter > 0, NotUnderpaidBatch());

        underpaid_.counter--;

        depositSubsidy(processor.messagePoolIdPayment(batch));

        uint256 cost = _send(centrifugeId, batch, underpaid_.gasLimit);
        require(cost > 0 && msg.value >= cost, CannotBeRepaid());

        if (underpaid_.counter == 0) delete underpaid[centrifugeId][batchHash];

        emit RepayBatch(centrifugeId, batch);
    }

    function _requestPoolFunding(PoolId poolId) internal {
        // NOTE: refund will never be shared across pools
        IRecoverable refund = subsidy[poolId].refund;
        if (!poolId.isNull()) {
            uint256 refundBalance = address(refund).balance;
            if (refundBalance == 0) return;

            // Send to the gateway GLOBAL_POT
            refund.recoverTokens(ETH_ADDRESS, address(this), refundBalance);

            // Extract from the GLOBAL_POT
            subsidy[GLOBAL_POT].value -= refundBalance.toUint96();
            _depositSubsidy(poolId, address(refund), refundBalance);
        }
    }

    /// @inheritdoc IGateway
    function setRefundAddress(PoolId poolId, IRecoverable refund) public auth {
        subsidy[poolId].refund = refund;
        emit SetRefundAddress(poolId, refund);
    }

    /// @inheritdoc IGateway
    function depositSubsidy(PoolId poolId) public payable {
        _depositSubsidy(poolId, msg.sender, msg.value);
    }

    function _depositSubsidy(PoolId poolId, address who, uint256 value) internal {
        require(address(subsidy[poolId].refund) != address(0), RefundAddressNotSet());
        subsidy[poolId].value += value.toUint96();
        emit DepositSubsidy(poolId, who, value);
    }

    /// @inheritdoc IGateway
    function withdrawSubsidy(PoolId poolId, address to, uint256 amount) external onlyAuthOrManager(poolId) {
        if (amount > subsidy[poolId].value) _requestPoolFunding(poolId);

        subsidy[poolId].value -= amount.toUint96();

        (bool success,) = payable(to).call{value: amount}(new bytes(0));
        require(success, CannotWithdraw());

        emit WithdrawSubsidy(poolId, to, amount);
    }

    /// @inheritdoc IGateway
    function startBatching() external auth {
        isBatching = true;
    }

    /// @inheritdoc IGateway
    function endBatching() external auth {
        require(isBatching, NoBatched());
        bytes32[] memory locators = TransientArrayLib.getBytes32(BATCH_LOCATORS_SLOT);

        isBatching = false;
        TransientArrayLib.clear(BATCH_LOCATORS_SLOT);

        for (uint256 i; i < locators.length; i++) {
            (uint16 centrifugeId, PoolId poolId) = _parseLocator(locators[i]);
            bytes32 outboundBatchSlot = _outboundBatchSlot(centrifugeId, poolId);
            uint128 gasLimit = _gasLimitSlot(centrifugeId, poolId).tloadUint128();

            _send(centrifugeId, TransientBytesLib.get(outboundBatchSlot), gasLimit);

            TransientBytesLib.clear(outboundBatchSlot);
            _gasLimitSlot(centrifugeId, poolId).tstore(uint256(0));
        }
    }

    /// @inheritdoc IGateway
    function blockOutgoing(uint16 centrifugeId, PoolId poolId, bool isBlocked) external onlyAuthOrManager(poolId) {
        isOutgoingBlocked[centrifugeId][poolId] = isBlocked;
        emit BlockOutgoing(centrifugeId, poolId, isBlocked);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _encodeLocator(uint16 centrifugeId, PoolId poolId) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(bytes2(centrifugeId), bytes8(poolId.raw())));
    }

    function _parseLocator(bytes32 locator) internal pure returns (uint16 centrifugeId, PoolId poolId) {
        centrifugeId = uint16(bytes2(locator));
        poolId = PoolId.wrap(uint64(bytes8(locator << 16)));
    }

    function _gasLimitSlot(uint16 centrifugeId, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode("batchGasLimit", centrifugeId, poolId));
    }

    function _outboundBatchSlot(uint16 centrifugeId, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode("outboundBatch", centrifugeId, poolId));
    }

    function subsidizedValue(PoolId poolId) external view returns (uint256) {
        return subsidy[poolId].value;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IGasService} from "./interfaces/IGasService.sol";
import {IMessageSender} from "./interfaces/IMessageSender.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IAdapterBlockSendingExt} from "./interfaces/IAdapter.sol";
import {IMessageProcessor} from "./interfaces/IMessageProcessor.sol";

import {Auth} from "../misc/Auth.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {TransientArrayLib} from "../misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "../misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "../misc/libraries/TransientStorageLib.sol";
import {Recoverable, IRecoverable, ETH_ADDRESS} from "../misc/Recoverable.sol";

/// @title  Gateway
/// @notice Routing contract that forwards outgoing messages to multiple adapters (1 full message, n-1 proofs)
///         and validates that multiple adapters have confirmed a message.
///
///         Supports batching multiple messages, as well as paying for methods manually or through pool-level subsidies.
///
///         Supports processing multiple duplicate messages in parallel by storing counts of messages
///         and proofs that have been received. Also implements a retry method for failed messages.
contract Gateway is Auth, Recoverable, IGateway {
    using MathLib for *;
    using BytesLib for bytes;
    using TransientStorageLib for bytes32;

    uint256 public constant GAS_FAIL_MESSAGE_STORAGE = 40_000; // check testMessageFailBenchmark
    PoolId public constant GLOBAL_POT = PoolId.wrap(0);
    bytes32 public constant BATCH_LOCATORS_SLOT = bytes32(uint256(keccak256("Centrifuge/batch-locators")) - 1);

    uint16 public immutable localCentrifugeId;

    // Dependencies
    IRoot public immutable root;
    IGasService public gasService;
    IMessageProcessor public processor;
    IAdapterBlockSendingExt public adapter;

    // Outbound & payments
    bool public transient isBatching;
    uint256 public transient fuel;
    address public transient transactionRefund;
    uint128 public transient extraGasLimit;
    mapping(PoolId => Funds) public subsidy;
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

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function file(bytes32 what, address instance) external auth {
        if (what == "gasService") gasService = IGasService(instance);
        else if (what == "processor") processor = IMessageProcessor(instance);
        else if (what == "adapter") adapter = IAdapterBlockSendingExt(instance);
        else revert FileUnrecognizedParam();

        emit File(what, instance);
    }

    receive() external payable {
        _subsidizePool(GLOBAL_POT, msg.sender, msg.value);
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

            _process(centrifugeId, message);
        }
    }

    function _process(uint16 centrifugeId, bytes memory message) internal {
        try processor.handle{gas: gasleft() - GAS_FAIL_MESSAGE_STORAGE}(centrifugeId, message) {
            emit ExecuteMessage(centrifugeId, message);
        } catch (bytes memory err) {
            bytes32 messageHash = keccak256(message);
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

        emit ExecuteMessage(centrifugeId, message);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageSender
    function send(uint16 centrifugeId, bytes calldata message) external pauseable auth {
        require(message.length > 0, EmptyMessage());

        PoolId poolId = processor.messagePoolId(message);

        emit PrepareMessage(centrifugeId, poolId, message);

        uint128 gasLimit = gasService.messageGasLimit(centrifugeId, message) + extraGasLimit;
        extraGasLimit = 0;

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
        } else {
            _send(centrifugeId, message, gasLimit);
        }
    }

    function _send(uint16 centrifugeId, bytes memory batch, uint128 batchGasLimit) internal returns (bool succeeded) {
        PoolId adapterPoolId = processor.messagePoolId(batch);
        PoolId paymentPoolId = processor.messagePoolIdPayment(batch);
        uint256 cost = adapter.estimate(centrifugeId, batch, batchGasLimit);

        // Ensure sufficient funds are available
        if (transactionRefund != address(0)) {
            require(cost <= fuel, NotEnoughTransactionGas());
            fuel -= cost;
            if (adapter.isOutgoingBlocked(centrifugeId, adapterPoolId)) {
                _addUnpaidBatch(centrifugeId, batch, true, batchGasLimit);
                _subsidizePool(paymentPoolId, address(subsidy[paymentPoolId].refund), cost);
                return false;
            }
        } else {
            if (adapter.isOutgoingBlocked(centrifugeId, adapterPoolId)) {
                _addUnpaidBatch(centrifugeId, batch, true, batchGasLimit);
                return false;
            }

            // Subsidized pool payment
            if (cost > subsidy[paymentPoolId].value) {
                _requestPoolFunding(paymentPoolId);
            }

            if (cost <= subsidy[paymentPoolId].value) {
                subsidy[paymentPoolId].value -= cost.toUint96();
            } else {
                _addUnpaidBatch(centrifugeId, batch, true, batchGasLimit);
                return false;
            }
        }

        adapter.send{value: cost}(
            centrifugeId,
            batch,
            batchGasLimit,
            transactionRefund != address(0) ? transactionRefund : address(subsidy[paymentPoolId].refund)
        );

        return true;
    }

    /// @inheritdoc IGateway
    function addUnpaidMessage(uint16 centrifugeId, bytes memory message, bool isSubsidized) external auth {
        uint128 gasLimit = gasService.messageGasLimit(centrifugeId, message) + extraGasLimit;
        extraGasLimit = 0;
        emit PrepareMessage(centrifugeId, processor.messagePoolId(message), message);
        _addUnpaidBatch(centrifugeId, message, isSubsidized, gasLimit);
    }

    function _addUnpaidBatch(uint16 centrifugeId, bytes memory message, bool isSubsidized, uint128 gasLimit) internal {
        bytes32 batchHash = keccak256(message);

        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        underpaid_.counter++;
        underpaid_.gasLimit = gasLimit;
        underpaid_.isSubsidized = isSubsidized;

        emit UnderpaidBatch(centrifugeId, message, batchHash);
    }

    /// @inheritdoc IGateway
    function repay(uint16 centrifugeId, bytes memory batch) external payable pauseable {
        bytes32 batchHash = keccak256(batch);
        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        require(underpaid_.counter > 0, NotUnderpaidBatch());

        underpaid_.counter--;

        if (!underpaid_.isSubsidized) _startTransactionPayment(msg.sender);

        require(_send(centrifugeId, batch, underpaid_.gasLimit), CannotBeRepaid());

        if (!underpaid_.isSubsidized) _endTransactionPayment();

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
            _subsidizePool(poolId, address(refund), refundBalance);
        }
    }

    /// @inheritdoc IGateway
    function setExtraGasLimit(uint128 gas) public auth {
        extraGasLimit = gas;
    }

    /// @inheritdoc IGateway
    function setRefundAddress(PoolId poolId, IRecoverable refund) public auth {
        subsidy[poolId].refund = refund;
        emit SetRefundAddress(poolId, refund);
    }

    /// @inheritdoc IGateway
    function subsidizePool(PoolId poolId) public payable {
        _subsidizePool(poolId, msg.sender, msg.value);
    }

    function _subsidizePool(PoolId poolId, address who, uint256 value) internal {
        require(address(subsidy[poolId].refund) != address(0), RefundAddressNotSet());
        subsidy[poolId].value += value.toUint96();
        emit SubsidizePool(poolId, who, value);
    }

    /// @inheritdoc IGateway
    function startTransactionPayment(address payer) external payable auth {
        _startTransactionPayment(payer);
    }

    function _startTransactionPayment(address payer) internal {
        transactionRefund = payer;
        fuel += msg.value;
    }

    /// @inheritdoc IGateway
    function endTransactionPayment() external auth {
        _endTransactionPayment();
    }

    function _endTransactionPayment() internal {
        if (transactionRefund == address(0)) return;

        // Reset before external call
        uint256 fuel_ = fuel;
        address transactionRefund_ = transactionRefund;
        fuel = 0;
        transactionRefund = address(0);

        if (fuel_ > 0) {
            (bool success,) = payable(transactionRefund_).call{value: fuel_}(new bytes(0));

            if (!success) {
                // If refund fails, move remaining fuel to global pot
                _subsidizePool(GLOBAL_POT, transactionRefund_, fuel_);
            }
        }
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

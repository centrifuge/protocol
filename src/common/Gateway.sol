// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IGasService} from "./interfaces/IGasService.sol";
import {IMessageSender} from "./interfaces/IMessageSender.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IMessageProcessor} from "./interfaces/IMessageProcessor.sol";

import {Auth} from "../misc/Auth.sol";
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
    using BytesLib for bytes;
    using TransientStorageLib for bytes32;

    PoolId public constant GLOBAL_POT = PoolId.wrap(0);
    bytes32 public constant BATCH_LOCATORS_SLOT = bytes32(uint256(keccak256("Centrifuge/batch-locators")) - 1);

    // Dependencies
    IRoot public immutable root;
    IGasService public gasService;
    IMessageProcessor public processor;
    IAdapter public adapter;

    // Outbound & payments
    bool public transient isBatching;
    uint256 public transient fuel;
    address public transient transactionRefund;
    uint128 public transient extraGasLimit;
    mapping(PoolId => Funds) public subsidy;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => Underpaid)) public underpaid;

    // Inbound
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => uint256)) public failedMessages;

    constructor(IRoot root_, IGasService gasService_, address deployer) Auth(deployer) {
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
        else if (what == "adapter") adapter = IAdapter(instance);
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
        IMessageProcessor processor_ = processor;
        bytes memory remaining = batch;

        while (remaining.length > 0) {
            uint256 length = processor_.messageLength(remaining);
            bytes memory message = remaining.slice(0, length);
            remaining = remaining.slice(length, remaining.length - length);

            try processor_.handle(centrifugeId, message) {
                emit ExecuteMessage(centrifugeId, message);
            } catch (bytes memory err) {
                bytes32 messageHash = keccak256(message);
                failedMessages[centrifugeId][messageHash]++;
                emit FailMessage(centrifugeId, message, err);
            }
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
            _send(centrifugeId, poolId, message, gasLimit);
        }
    }

    function _send(uint16 centrifugeId, PoolId poolId, bytes memory batch, uint128 batchGasLimit)
        internal
        returns (bool succeeded)
    {
        uint256 cost = adapter.estimate(centrifugeId, batch, batchGasLimit);

        // Ensure sufficient funds are available
        if (transactionRefund != address(0)) {
            require(cost <= fuel, NotEnoughTransactionGas());
            fuel -= cost;
        } else {
            // Subsidized pool payment
            if (cost > subsidy[poolId].value) {
                _requestPoolFunding(poolId);
            }

            if (cost <= subsidy[poolId].value) {
                subsidy[poolId].value -= uint96(cost);
            } else {
                _addUnpaidBatch(centrifugeId, batch, batchGasLimit);
                return false;
            }
        }

        adapter.send{value: cost}(
            centrifugeId,
            batch,
            batchGasLimit,
            transactionRefund != address(0) ? transactionRefund : address(subsidy[poolId].refund)
        );

        return true;
    }

    /// @inheritdoc IGateway
    function addUnpaidMessage(uint16 centrifugeId, bytes memory message) external auth {
        _addUnpaidBatch(centrifugeId, message, gasService.messageGasLimit(centrifugeId, message));
    }

    function _addUnpaidBatch(uint16 centrifugeId, bytes memory message, uint128 gasLimit) internal {
        bytes32 batchHash = keccak256(message);

        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        underpaid_.counter++;
        underpaid_.gasLimit = gasLimit;

        emit UnderpaidBatch(centrifugeId, message);
    }

    /// @inheritdoc IGateway
    function repay(uint16 centrifugeId, bytes memory batch) external payable pauseable {
        bytes32 batchHash = keccak256(batch);
        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        require(underpaid_.counter > 0, NotUnderpaidBatch());

        PoolId poolId = processor.messagePoolId(batch);
        if (msg.value > 0) subsidizePool(poolId);

        underpaid_.counter--;
        require(_send(centrifugeId, poolId, batch, underpaid_.gasLimit), InsufficientFundsForRepayment());

        emit RepayBatch(centrifugeId, batch);
    }

    function _requestPoolFunding(PoolId poolId) internal {
        IRecoverable refund = subsidy[poolId].refund;
        if (!poolId.isNull() && address(refund) != address(0)) {
            uint256 refundBalance = address(refund).balance;
            if (refundBalance == 0) return;

            // Send to the gateway GLOBAL_POT
            refund.recoverTokens(ETH_ADDRESS, address(this), refundBalance);

            // Extract from the GLOBAL_POT
            subsidy[GLOBAL_POT].value -= uint96(refundBalance);
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
        require(address(subsidy[poolId].refund) != address(0), RefundAddressNotSet());
        _subsidizePool(poolId, msg.sender, msg.value);
    }

    function _subsidizePool(PoolId poolId, address who, uint256 value) internal {
        subsidy[poolId].value += uint96(value);
        emit SubsidizePool(poolId, who, value);
    }

    /// @inheritdoc IGateway
    function startTransactionPayment(address payer) external payable auth {
        transactionRefund = payer;
        fuel += msg.value;
    }

    /// @inheritdoc IGateway
    function endTransactionPayment() external auth {
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

            _send(centrifugeId, poolId, TransientBytesLib.get(outboundBatchSlot), gasLimit);

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
}

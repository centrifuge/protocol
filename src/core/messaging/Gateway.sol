// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IProtocolPauser} from "./interfaces/IProtocolPauser.sol";
import {IMessageProperties} from "./interfaces/IMessageProperties.sol";
import {IGateway, PROCESS_FAIL_MESSAGE_GAS, MESSAGE_MAX_LENGTH, ERR_MAX_LENGTH} from "./interfaces/IGateway.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {TransientArrayLib} from "../../misc/libraries/TransientArrayLib.sol";
import {TransientBytesLib} from "../../misc/libraries/TransientBytesLib.sol";
import {TransientStorageLib} from "../../misc/libraries/TransientStorageLib.sol";
import {ExcessivelySafeCallLib} from "../../misc/libraries/ExcessivelySafeCallLib.sol";

import {PoolId} from "../types/PoolId.sol";

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
    using ExcessivelySafeCallLib for address;

    bytes32 public constant BATCH_LOCATORS_SLOT = bytes32(uint256(keccak256("Centrifuge/batch-locators")) - 1);

    uint16 public immutable localCentrifugeId;

    // Dependencies
    IAdapter public adapter;
    IMessageHandler public processor;
    IMessageProperties public messageProperties;
    IProtocolPauser public immutable pauser;

    // Management
    mapping(PoolId => mapping(address => bool)) public manager;

    // Outbound & payments
    bool public transient isBatching;
    bool internal transient _isSendingBatch;
    address internal transient _batcher;
    mapping(uint16 centrifugeId => mapping(PoolId => bool)) public isOutgoingBlocked;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => Underpaid)) public underpaid;

    // Inbound
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => uint256)) public failedMessages;

    constructor(uint16 localCentrifugeId_, IProtocolPauser pauser_, address deployer) Auth(deployer) {
        pauser = pauser_;
        localCentrifugeId = localCentrifugeId_;
    }

    modifier pauseable() {
        require(!pauser.paused(), Paused());
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
        if (what == "messageProperties") messageProperties = IMessageProperties(instance);
        else if (what == "processor") processor = IMessageHandler(instance);
        else if (what == "adapter") adapter = IAdapter(instance);
        else revert FileUnrecognizedParam();

        emit File(what, instance);
    }

    /// @inheritdoc IGateway
    function updateManager(PoolId poolId, address who, bool canManage) external auth {
        manager[poolId][who] = canManage;
        emit UpdateManager(poolId, who, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes memory batch) public pauseable auth {
        PoolId batchPoolId = messageProperties.messagePoolId(batch);

        bytes memory remaining = batch;
        while (remaining.length > 0) {
            uint256 length = messageProperties.messageLength(remaining);
            bytes memory message = remaining.slice(0, length);

            if (remaining.length != batch.length) {
                // Only check if batching
                require(batchPoolId == messageProperties.messagePoolId(message), MalformedBatch());
            }

            remaining = remaining.slice(length, remaining.length - length);
            bytes32 messageHash = keccak256(message);
            uint128 gasLimit = messageProperties.messageProcessingGasLimit(localCentrifugeId, message);
            require(gasleft() >= gasLimit, NotEnoughGas());

            _safeProcess(centrifugeId, message, messageHash, gasLimit);
        }
    }

    function _safeProcess(uint16 centrifugeId, bytes memory message, bytes32 messageHash, uint128 gasLimit) internal {
        (bool success, bytes memory err) = address(processor)
            .excessivelySafeCall(
                gasLimit - PROCESS_FAIL_MESSAGE_GAS,
                0,
                ERR_MAX_LENGTH,
                abi.encodeWithSelector(IMessageHandler.handle.selector, centrifugeId, message)
            );

        if (success) {
            emit ExecuteMessage(centrifugeId, messageHash);
        } else {
            failedMessages[centrifugeId][messageHash]++;
            emit FailMessage(centrifugeId, messageHash, err);
        }
    }

    /// @inheritdoc IGateway
    function retry(uint16 centrifugeId, bytes memory message) external pauseable {
        bytes32 messageHash = keccak256(message);
        require(failedMessages[centrifugeId][messageHash] > 0, NotFailedMessage());

        failedMessages[centrifugeId][messageHash]--;
        processor.handle(centrifugeId, message);

        emit ExecuteMessage(centrifugeId, messageHash);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGateway
    function send(uint16 centrifugeId, bytes calldata message, bool unpaidMode, address refund)
        external
        payable
        pauseable
        auth
    {
        require(message.length > 0, EmptyMessage());
        require(message.length <= MESSAGE_MAX_LENGTH, TooLongMessage());
        require(!_isSendingBatch, ReentrantBatchCreation());

        PoolId poolId = messageProperties.messagePoolId(message);
        emit PrepareMessage(centrifugeId, poolId, message);

        uint128 gasLimit = messageProperties.messageOverallGasLimit(centrifugeId, message);
        if (isBatching) {
            require(msg.value == 0, NotPayable());

            bytes32 batchSlot = _outboundBatchSlot(centrifugeId, poolId);
            bytes memory previousMessage = TransientBytesLib.get(batchSlot);

            bytes32 gasLimitSlot = _gasLimitSlot(centrifugeId, poolId);
            uint128 newGasLimit = gasLimitSlot.tloadUint128() + gasLimit;
            require(newGasLimit <= messageProperties.maxBatchGasLimit(centrifugeId), BatchTooExpensive());
            gasLimitSlot.tstore(uint256(newGasLimit));

            if (previousMessage.length == 0) {
                TransientArrayLib.push(BATCH_LOCATORS_SLOT, _encodeLocator(centrifugeId, poolId));
            }

            TransientBytesLib.append(batchSlot, message);
        } else {
            require(gasLimit <= messageProperties.maxBatchGasLimit(centrifugeId), BatchTooExpensive());

            uint256 cost = _send(centrifugeId, message, gasLimit, refund, unpaidMode, msg.value);
            _refund(refund, msg.value - cost);
        }
    }

    function _send(
        uint16 centrifugeId,
        bytes memory batch,
        uint128 batchGasLimit,
        address refund,
        bool unpaidMode,
        uint256 fuel
    ) internal returns (uint256 cost) {
        PoolId adapterPoolId = messageProperties.messagePoolId(batch);
        require(!isOutgoingBlocked[centrifugeId][adapterPoolId], OutgoingBlocked());

        cost = adapter.estimate(centrifugeId, batch, batchGasLimit);
        if (fuel >= cost) {
            adapter.send{value: cost}(centrifugeId, batch, batchGasLimit, refund);
        } else if (unpaidMode) {
            _addUnpaidBatch(centrifugeId, batch, batchGasLimit);
            cost = 0;
        } else {
            revert NotEnoughGas();
        }
    }

    function _refund(address refund, uint256 fuel) internal {
        if (fuel > 0) {
            (bool success,) = payable(refund).call{value: fuel}("");
            require(success, CannotRefund());
        }
    }

    function _addUnpaidBatch(uint16 centrifugeId, bytes memory message, uint128 gasLimit) internal {
        bytes32 batchHash = keccak256(message);

        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        underpaid_.counter++;
        underpaid_.gasLimit = gasLimit;

        emit UnderpaidBatch(centrifugeId, message, batchHash);
    }

    /// @inheritdoc IGateway
    function repay(uint16 centrifugeId, bytes memory batch, address refund) external payable pauseable {
        bytes32 batchHash = keccak256(batch);
        Underpaid storage underpaid_ = underpaid[centrifugeId][batchHash];
        require(underpaid_.counter > 0, NotUnderpaidBatch());

        underpaid_.counter--;

        uint256 cost = _send(centrifugeId, batch, underpaid_.gasLimit, refund, false, msg.value);
        _refund(refund, msg.value - cost);

        if (underpaid_.counter == 0) delete underpaid[centrifugeId][batchHash];

        emit RepayBatch(centrifugeId, batch);
    }

    /// @inheritdoc IGateway
    function withBatch(bytes memory data, uint256 callbackValue, address refund) public payable {
        require(callbackValue <= msg.value, NotEnoughValueForCallback());
        require(!_isSendingBatch, ReentrantBatchCreation());

        bool isNested = isBatching;
        isBatching = true;

        _batcher = msg.sender;
        (bool success, bytes memory returnData) = msg.sender.call{value: callbackValue}(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, CallFailedWithEmptyRevert());

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }

        // Force the user to call lockCallback()
        require(address(_batcher) == address(0), CallbackWasNotLocked());

        if (isNested) {
            _refund(refund, msg.value - callbackValue);
        } else {
            uint256 cost = _endBatching(msg.value - callbackValue, refund);
            _refund(refund, msg.value - callbackValue - cost);
        }
    }

    function _endBatching(uint256 fuel, address refund) internal returns (uint256 cost) {
        require(isBatching, NoBatched());
        bytes32[] memory locators = TransientArrayLib.getBytes32(BATCH_LOCATORS_SLOT);

        TransientArrayLib.clear(BATCH_LOCATORS_SLOT);

        _isSendingBatch = true;

        for (uint256 i; i < locators.length; i++) {
            (uint16 centrifugeId, PoolId poolId) = _parseLocator(locators[i]);
            bytes32 outboundBatchSlot = _outboundBatchSlot(centrifugeId, poolId);
            bytes memory batch = TransientBytesLib.get(outboundBatchSlot);

            cost += _send(
                centrifugeId, batch, _gasLimitSlot(centrifugeId, poolId).tloadUint128(), refund, false, fuel - cost
            );

            TransientBytesLib.clear(outboundBatchSlot);
            _gasLimitSlot(centrifugeId, poolId).tstore(uint256(0));
        }

        _isSendingBatch = false;
        isBatching = false;
    }

    /// @inheritdoc IGateway
    function withBatch(bytes memory data, address refund) external payable {
        withBatch(data, 0, refund);
    }

    /// @inheritdoc IGateway
    function lockCallback() external {
        require(_batcher != address(0), CallbackIsLocked());
        require(msg.sender == _batcher, CallbackWasNotFromSender());
        _batcher = address(0);
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
}

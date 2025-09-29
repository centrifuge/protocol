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
    bool public transient unpaidMode;
    mapping(uint16 centrifugeId => mapping(PoolId => bool)) public isOutgoingBlocked;
    mapping(uint16 centrifugeId => mapping(bytes32 batchHash => Underpaid)) public underpaid;

    // Inbound
    mapping(uint16 centrifugeId => mapping(bytes32 messageHash => uint256)) public failedMessages;

    constructor(uint16 localCentrifugeId_, IRoot root_, IGasService gasService_, address deployer) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        root = root_;
        gasService = gasService_;
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

    receive() external payable {}

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
    function send(uint16 centrifugeId, bytes calldata message, uint128 extraGasLimit, address refund)
        external
        payable
        pauseable
        auth
    {
        require(message.length > 0, EmptyMessage());

        PoolId poolId = processor.messagePoolId(message);
        emit PrepareMessage(centrifugeId, poolId, message);

        uint128 gasLimit = gasService.messageGasLimit(centrifugeId, message) + extraGasLimit;
        if (isBatching) {
            require(msg.value == 0, NotPayable());
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
            _send(centrifugeId, message, gasLimit, refund);
        }
    }

    function _send(uint16 centrifugeId, bytes memory batch, uint128 batchGasLimit, address refund) internal {
        PoolId adapterPoolId = processor.messagePoolId(batch);
        require(!isOutgoingBlocked[centrifugeId][adapterPoolId], OutgoingBlocked());

        uint256 cost = adapter.estimate(centrifugeId, batch, batchGasLimit);
        if (msg.value >= cost) {
            adapter.send{value: cost}(centrifugeId, batch, batchGasLimit, refund);
        } else if (unpaidMode) {
            _addUnpaidBatch(centrifugeId, batch, batchGasLimit);
            cost = 0;
        } else {
            revert NotEnoughGas();
        }

        if (msg.value > cost) {
            (bool success,) = payable(refund).call{value: msg.value - cost}("");
            require(success, CannotRefund());
        }
    }

    /// @inheritdoc IGateway
    function setUnpaidMode(bool enabled) external auth {
        unpaidMode = enabled;
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

        _send(centrifugeId, batch, underpaid_.gasLimit, refund);

        if (underpaid_.counter == 0) delete underpaid[centrifugeId][batchHash];

        emit RepayBatch(centrifugeId, batch);
    }

    /// @inheritdoc IGateway
    function startBatching() external auth {
        isBatching = true;
    }

    /// @inheritdoc IGateway
    function endBatching(address refund) external payable auth {
        require(isBatching, NoBatched());
        bytes32[] memory locators = TransientArrayLib.getBytes32(BATCH_LOCATORS_SLOT);

        isBatching = false;
        TransientArrayLib.clear(BATCH_LOCATORS_SLOT);

        for (uint256 i; i < locators.length; i++) {
            (uint16 centrifugeId, PoolId poolId) = _parseLocator(locators[i]);
            bytes32 outboundBatchSlot = _outboundBatchSlot(centrifugeId, poolId);
            uint128 gasLimit = _gasLimitSlot(centrifugeId, poolId).tloadUint128();
            bytes memory batch = TransientBytesLib.get(outboundBatchSlot);

            _send(centrifugeId, batch, gasLimit, refund);

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
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IMessageSender} from "src/common/interfaces/IMessageSender.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";

contract Gateway is Auth, IGateway {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IAdapter public adapter; // TODO: support multiple adapters
    IMessageHandler public handler;

    mapping(uint32 chainId => bytes) public /*transient*/ batch;
    uint32[] public /*transient*/ chainIds;
    bool public /*transient*/ isBatching;

    /// @notice The payer of the transaction.
    address public /*transient*/ payableSource;

    constructor(address deployer) Auth(deployer) {}

    function file(bytes32 what, address data) external auth {
        if (what == "adapter") adapter = IAdapter(data);
        else if (what == "handle") handler = IMessageHandler(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @inheritdoc IGateway
    function setPayableSource(address source_) external auth {
        payableSource = source_;
    }

    /// @inheritdoc IGateway
    function startBatch() external auth {
        isBatching = true;
    }

    /// @inheritdoc IGateway
    function endBatch() external auth {
        require(isBatching, NoBatched());

        for (uint256 i; i < chainIds.length; i++) {
            uint32 chainId = chainIds[i];
            _send(chainId, batch[chainId]);
            delete batch[chainId];
            delete chainIds[i];
        }

        isBatching = false;
    }

    /// @inheritdoc IMessageHandler
    function handle(bytes memory message) external auth {
        // TODO: add some gateway stuff
        while (message.length > 0) {
            handler.handle(message);

            uint16 messageLength = message.messageLength();

            // TODO: remove this when registerAsset is merged
            if (message.messageType() == MessageType.RegisterAsset) {
                return;
            }

            // TODO: optimize with assembly to just shift the pointer in the array
            message = message.slice(messageLength, message.length - messageLength);
        }
    }

    /// @inheritdoc IMessageSender
    function send(uint32 chainId_, bytes memory message) external auth {
        if (isBatching) {
            bytes storage previousMessage = batch[chainId_];
            if (previousMessage.length == 0) {
                chainIds.push(chainId_);
                batch[chainId_] = message;
            } else {
                batch[chainId_] = bytes.concat(previousMessage, message);
            }
        } else {
            _send(chainId_, message);
        }
    }

    function _send(uint32 chainId, bytes memory message) private {
        // TODO: some gateway stuff
        adapter.send(chainId, message);
    }
}

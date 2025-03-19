// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

/// An adapter that sends the message to the same gateway that send them
contract LocalhostAdapter is Auth, IAdapter {
    uint32 public chainId;
    IMessageHandler public immutable gateway;

    constructor(IMessageHandler gateway_) Auth(msg.sender) {
        gateway = gateway_;
    }

    /// @inheritdoc IAdapter
    function send(uint32 centrifugeId, bytes calldata payload, uint256, address) external payable {
        gateway.handle(centrifugeId, payload);
    }

    /// @inheritdoc IAdapter
    function estimate(uint32, bytes calldata, uint256 gasLimit) public pure returns (uint256 nativePriceQuote) {
        return gasLimit;
    }
}

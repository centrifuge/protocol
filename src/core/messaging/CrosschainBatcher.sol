// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../misc/Auth.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ICrosschainBatcher} from "./interfaces/ICrosschainBatcher.sol";

contract CrosschainBatcher is Auth, ICrosschainBatcher {
    /// @inheritdoc ICrosschainBatcher
    IGateway public gateway;

    address private transient _callbackSender;

    constructor(IGateway gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
    }

    /// @inheritdoc ICrosschainBatcher
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ICrosschainBatcher
    function lockCallback() external {
        require(_callbackSender != address(0), CallbackAlreadyLocked());
        require(msg.sender == _callbackSender, CallbackNotFromSender());
        _callbackSender = address(0);
    }

    /// @inheritdoc ICrosschainBatcher
    function withBatch(bytes memory data, uint256 value, address refund) public payable {
        require(value <= msg.value, NotEnoughValueForCallback());

        gateway.startBatching();

        _callbackSender = msg.sender;

        (bool success, bytes memory returnData) = msg.sender.call{value: value}(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, CallFailedWithEmptyRevert());

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }

        // Force the user to call lockCallback()
        require(_callbackSender == address(0), CallbackWasNotLocked());

        gateway.endBatching{value: msg.value - value}(refund);
    }

    /// @inheritdoc ICrosschainBatcher
    function withBatch(bytes memory data, address refund) external payable {
        withBatch(data, 0, refund);
    }
}

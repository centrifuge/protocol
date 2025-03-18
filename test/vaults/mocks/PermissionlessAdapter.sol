// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "src/misc/Auth.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

contract PermissionlessAdapter is Auth, IAdapter {
    IMessageHandler public immutable gateway;

    event Send(bytes message);

    constructor(address gateway_) Auth(msg.sender) {
        gateway = IMessageHandler(gateway_);
    }

    // --- Incoming ---
    function execute(bytes32, string calldata, string calldata, bytes calldata payload) external {
        gateway.handle(1, payload);
    }

    // --- Outgoing ---
    function send(uint32, bytes memory message, uint256, address) public payable {
        emit Send(message);
    }

    // Added to be ignored in coverage report
    function test() public {}

    function estimate(uint32, bytes calldata, uint256) public pure returns (uint256 estimation) {
        return 1.5 gwei;
    }
}

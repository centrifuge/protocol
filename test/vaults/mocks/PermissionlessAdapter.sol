// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "src/Auth.sol";

interface GatewayLike {
    function handle(bytes memory message) external;
}

contract PermissionlessAdapter is Auth {
    GatewayLike public immutable gateway;

    event Send(bytes message);

    constructor(address gateway_) Auth(msg.sender) {
        gateway = GatewayLike(gateway_);
    }

    // --- Incoming ---
    function execute(bytes32, string calldata, string calldata, bytes calldata payload) external {
        gateway.handle(payload);
    }

    // --- Outgoing ---
    function send(bytes memory message) public {
        emit Send(message);
    }

    // Added to be ignored in coverage report
    function test() public {}

    function estimate(bytes calldata, uint256) public pure returns (uint256 estimation) {
        return 1.5 gwei;
    }

    function pay(bytes calldata, address) external payable {}
}

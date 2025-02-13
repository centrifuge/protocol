// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Auth} from "src/vaults/Auth.sol";
import "test/vaults/mocks/Mock.sol";

interface GatewayLike {
    function handle(bytes memory message) external;
}

contract MockAdapter is Auth, Mock {
    GatewayLike public immutable gateway;

    mapping(bytes => uint256) public sent;

    constructor(address gateway_) Auth(msg.sender) {
        gateway = GatewayLike(gateway_);
    }

    function execute(bytes memory _message) external {
        GatewayLike(gateway).handle(_message);
    }

    function send(bytes calldata message) public {
        values_bytes["send"] = message;
        sent[message]++;
    }

    function estimate(bytes calldata, uint256 baseCost) public view returns (uint256 estimation) {
        estimation = values_uint256_return["estimate"] + baseCost;
    }

    function pay(bytes calldata, address) external payable {
        callWithValue("pay", msg.value);
    }
    // Added to be ignored in coverage report

    function test() public {}
}

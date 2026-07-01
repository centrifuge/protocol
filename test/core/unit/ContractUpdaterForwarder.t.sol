// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {ContractUpdateLib} from "../../../src/core/utils/ContractUpdateLib.sol";
import {ContractUpdaterForwarder} from "../../../src/core/utils/ContractUpdaterForwarder.sol";
import {IContractUpdateGatewayHandler} from "../../../src/core/messaging/interfaces/IGatewayHandlers.sol";

import "forge-std/Test.sol";

contract ContractUpdaterForwarderTest is Test {
    ContractUpdaterForwarder forwarder;

    address immutable envoy = makeAddr("envoy");
    address immutable contractUpdater = makeAddr("contractUpdater");
    address immutable target = makeAddr("target");
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16("sc"));

    function setUp() public {
        forwarder = new ContractUpdaterForwarder(envoy, IContractUpdateGatewayHandler(contractUpdater));
    }

    function testFromHubOnlyEnvoy(bytes calldata inner) public {
        bytes memory payload = ContractUpdateLib.wrap(SC_A, target, inner);

        vm.prank(makeAddr("notEnvoy"));
        vm.expectRevert(ContractUpdaterForwarder.NotEnvoy.selector);
        forwarder.fromHub(POOL_A, payload);
    }

    function testFromHubRejectsValue(bytes calldata inner) public {
        bytes memory payload = ContractUpdateLib.wrap(SC_A, target, inner);

        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(ContractUpdaterForwarder.UnexpectedValue.selector);
        forwarder.fromHub{value: 1}(POOL_A, payload);
    }

    function testFromHubUnwrapsAndForwardsToContractUpdater(bytes calldata inner) public {
        bytes memory payload = ContractUpdateLib.wrap(SC_A, target, inner);

        // The forwarder unwraps and calls the (unchanged) ContractUpdater.trustedCall — so the eventual
        // target.trustedCall has the ContractUpdater as msg.sender, preserving the spoke-side anchor.
        bytes memory expected =
            abi.encodeWithSelector(IContractUpdateGatewayHandler.trustedCall.selector, POOL_A, SC_A, target, inner);
        vm.mockCall(contractUpdater, expected, "");
        vm.expectCall(contractUpdater, expected);

        vm.prank(envoy);
        forwarder.fromHub(POOL_A, payload);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {IMessageHandler} from "src/core/messaging/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/core/messaging/interfaces/IAdapter.sol";
import {CCIPAdapter} from "src/adapters/CCIPAdapter.sol";

import {CreateXScript} from "../utils/CreateXScript.sol";

bytes constant MESSAGE = "abc";
uint128 constant GAS_LIMIT = 500_000;

uint64 constant CCIP_SEPOLIA_BASE_ID = 10344971235874465080;
address constant CCIP_SEPOLIA_BASE_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;

uint64 constant CCIP_SEPOLIA_ETHEREUM_ID = 16015286601757825753;
address constant CCIP_SEPOLIA_ETHEREUM_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

bytes constant ENTRYPOINT_NAME = "MockEntrypoint-cfg"; // 0x6bB60C397FDD8a274E1cb8E098F10d4f9499b784
bytes constant CCIP_ADAPTER_NAME = "CCIPAdapter-cfg"; //0x6bB60C397FDD8a274E1cb8E098F10d4f9499b784

contract MockEntrypoint is IMessageHandler {
    // Check event in https://sepolia.basescan.org/address/0xbd3873aEd2dB4680a6D84586c9F3F691B54462cb#events
    event MsgReceived(bytes);

    function handle(uint16, bytes memory message) external {
        emit MsgReceived(message);
    }

    function send(IAdapter adapter) external payable {
        adapter.send{value: msg.value}(0, MESSAGE, GAS_LIMIT, address(0));
    }
}

contract CCIPEthereumTestScript is Script, CreateXScript {
    function run() public {
        vm.startBroadcast();

        setUpCreateXFactory();

        MockEntrypoint entrypoint =
            MockEntrypoint(create3(keccak256(ENTRYPOINT_NAME), abi.encodePacked(type(MockEntrypoint).creationCode)));

        CCIPAdapter ccip = CCIPAdapter(
            create3(
                keccak256(CCIP_ADAPTER_NAME),
                abi.encodePacked(
                    type(CCIPAdapter).creationCode, abi.encode(entrypoint, CCIP_SEPOLIA_ETHEREUM_ROUTER, msg.sender)
                )
            )
        );

        ccip.wire(0, abi.encode(CCIP_SEPOLIA_BASE_ID, address(ccip)));
        entrypoint.send{value: ccip.estimate(0, MESSAGE, GAS_LIMIT)}(ccip);

        vm.stopBroadcast();

        console.log("entrypoint: ", address(entrypoint));
        console.log("CCIPAdapter: ", address(ccip));
    }
}

contract CCIPBaseTestScript is Script, CreateXScript {
    function run() public {
        vm.startBroadcast();

        setUpCreateXFactory();

        MockEntrypoint entrypoint =
            MockEntrypoint(create3(keccak256(ENTRYPOINT_NAME), abi.encodePacked(type(MockEntrypoint).creationCode)));

        CCIPAdapter ccip = CCIPAdapter(
            create3(
                keccak256(CCIP_ADAPTER_NAME),
                abi.encodePacked(
                    type(CCIPAdapter).creationCode, abi.encode(entrypoint, CCIP_SEPOLIA_BASE_ROUTER, msg.sender)
                )
            )
        );

        ccip.wire(0, abi.encode(CCIP_SEPOLIA_ETHEREUM_ID, address(ccip)));

        vm.stopBroadcast();

        console.log("entrypoint: ", address(entrypoint));
        console.log("CCIPAdapter: ", address(ccip));
    }
}

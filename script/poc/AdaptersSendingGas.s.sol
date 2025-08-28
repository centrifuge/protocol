// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {WormholeAdapter} from "src/adapters/WormholeAdapter.sol";
import {LayerZeroAdapter} from "src/adapters/LayerZeroAdapter.sol";

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

contract MockEntrypoint is IMessageHandler {
    uint128 constant GAS_LIMIT = 500_000;

    event GasReceived(uint256 gas);

    function handle(uint16, bytes memory) external payable {
        emit GasReceived(msg.value);
    }

    function send(IAdapter adapter) external payable {
        adapter.send{value: msg.value}(0, "a", GAS_LIMIT, msg.value - GAS_LIMIT, address(0));
    }
}

contract AdaptersSendingGasScript is Script, CreateXScript {
    uint16 constant WORMHOLE_SEPOPLIA_ETH_ID = 10002;
    address constant WORMHOLE_SEPOLIA_ETH_RELAYER = 0x7B1bD7a6b4E61c2a123AC6BC2cbfC614437D0470;

    uint32 constant LAYER_ZERO_SEPOPLIA_ETH_ID = 40161;
    address constant LAYER_ZERO_SEPOPLIA_ETH_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;

    function run() public {
        vm.startBroadcast();

        setUpCreateXFactory();

        MockEntrypoint entrypoint = MockEntrypoint(
            create3(keccak256("test-gas-value-MockEntrypoint"), abi.encodePacked(type(MockEntrypoint).creationCode))
        );

        WormholeAdapter wormhole = WormholeAdapter(
            create3(
                keccak256("test-gas-value-WormholeAdapter"),
                abi.encodePacked(
                    type(WormholeAdapter).creationCode, abi.encode(entrypoint, WORMHOLE_SEPOLIA_ETH_RELAYER, msg.sender)
                )
            )
        );

        LayerZeroAdapter layerZero = LayerZeroAdapter(
            create3(
                keccak256("test-gas-value-LayerZeroAdapter"),
                abi.encodePacked(
                    type(LayerZeroAdapter).creationCode,
                    abi.encode(entrypoint, LAYER_ZERO_SEPOPLIA_ETH_ENDPOINT, msg.sender, msg.sender)
                )
            )
        );

        wormhole.wire(0, WORMHOLE_SEPOPLIA_ETH_ID, address(wormhole));
        layerZero.wire(0, LAYER_ZERO_SEPOPLIA_ETH_ID, address(layerZero));

        entrypoint.send{value: 500_123}(wormhole);
        entrypoint.send{value: 500_123}(layerZero);

        vm.stopBroadcast();

        console.log("entrypoint: ", address(entrypoint));
        console.log("Wormhole: ", address(wormhole));
        console.log("layerZero: ", address(layerZero));
    }
}

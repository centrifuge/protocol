// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {WormholeAdapter} from "src/adapters/WormholeAdapter.sol";
import {LayerZeroAdapter} from "src/adapters/LayerZeroAdapter.sol";

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

bytes constant MESSAGE = "payload";
uint128 constant GAS_LIMIT = 500_000;
uint128 constant GAS_VALUE = 200_000;

contract MockEntrypoint is IMessageHandler {
    event GasReceived(uint256 gas);

    function handle(uint16, bytes memory) external payable {
        emit GasReceived(msg.value);
    }

    function send(IAdapter adapter) external payable {
        adapter.send{value: msg.value}(0, MESSAGE, GAS_LIMIT, GAS_VALUE, address(0));
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

        uint256 wormholeGas = wormhole.estimate(0, MESSAGE, GAS_LIMIT, GAS_VALUE);
        entrypoint.send{value: wormholeGas}(wormhole);

        uint256 layerZeroGas = layerZero.estimate(0, MESSAGE, GAS_LIMIT, GAS_VALUE);
        entrypoint.send{value: layerZeroGas}(layerZero);

        vm.stopBroadcast();

        console.log("entrypoint: ", address(entrypoint)); // 0xc9d550e6A3B0D68dCfE5Bb9A159fae5805eA898B
        console.log("Wormhole: ", address(wormhole)); // 0xbccC9e078c1cE886A6923A9F094413F907cb9277
        console.log("layerZero: ", address(layerZero)); // 0xE1A56Ee71F6A1B486f23b2DE2B7bC1986bed0485
    }
}

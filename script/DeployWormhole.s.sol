
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

import { WormholeAdapter } from "src/common/adapters/WormholeAdapter.sol";

import "forge-std/Script.sol";

contract DeployWormhole is Script, CreateXScript {
    address root = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;
    address guardian = 0xFEE13c017693a4706391D516ACAbF6789D5c3157;
    address multiAdapter = 0x457C91384C984b1659157160e8543adb12BC5317;
    address relayer = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;

    bytes32 version;
    /**
     * @dev Generates a salt for contract deployment
     * @param contractName The name of the contract
     * @return salt A deterministic salt based on contract name and optional VERSION
     */
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        if (version != bytes32(0)) {
            return keccak256(abi.encodePacked(contractName, version));
        }
        return keccak256(abi.encodePacked(contractName));
    }

    function run() public {
        vm.startBroadcast();

        version = keccak256(abi.encodePacked("3"));

        setUpCreateXFactory();

        WormholeAdapter wormholeAdapter = WormholeAdapter(
            create3(
                generateSalt("wormholeAdapter"),
                abi.encodePacked(
                    type(WormholeAdapter).creationCode,
                    abi.encode(multiAdapter, relayer, msg.sender)
                )
            )
        );

        require(address(wormholeAdapter) == 0x6b98679eEC5b5DE3A803Dc801B2f12aDdDCD39Ec);

        wormholeAdapter.rely(root);
        wormholeAdapter.rely(guardian);
        wormholeAdapter.deny(msg.sender);

        vm.stopBroadcast();
    }
}
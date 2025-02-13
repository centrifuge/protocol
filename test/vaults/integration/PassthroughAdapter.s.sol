// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Deployer} from "../../script/Deployer.sol";
import {PassthroughAdapter} from "./PassthroughAdapter.sol";

contract PassthroughAdapterScript is Deployer {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        adminSafe = vm.envAddress("ADMIN");

        deploy(msg.sender);
        PassthroughAdapter router = new PassthroughAdapter();
        wire(address(router));

        router.file("gateway", address(gateway));
        router.file("sourceChain", vm.envString("SOURCE_CHAIN"));
        router.file("sourceAddress", toString(address(router)));

        removeDeployerAccess(address(router), msg.sender);

        vm.stopBroadcast();
    }

    function toString(address account) public pure returns (string memory) {
        return toString(abi.encodePacked(account));
    }

    function toString(bytes memory data) public pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(data[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }
}

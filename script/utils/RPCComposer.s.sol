// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

abstract contract RPCComposer is Script {
    function _rpcUrl(string memory network) internal view returns (string memory) {
        string memory json = vm.readFile(string.concat("env/", network, ".json"));
        string memory baseUrl = vm.parseJsonString(json, ".network.baseRpcUrl");
        string memory apiKey = keccak256(bytes(network)) == keccak256("plume")
            ? vm.envString("PLUME_API_KEY")
            : vm.envString("ALCHEMY_API_KEY");
        return string.concat(baseUrl, apiKey);
    }
}

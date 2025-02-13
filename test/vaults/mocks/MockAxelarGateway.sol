// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "test/mocks/Mock.sol";

contract MockAxelarGateway is Mock {
    constructor() {}

    function validateContractCall(bytes32, string calldata, string calldata, bytes32) public view returns (bool) {
        return values_bool_return["validateContractCall"];
    }

    function callContract(string calldata destinationChain, string calldata contractAddress, bytes calldata payload)
        public
    {
        values_string["destinationChain"] = destinationChain;
        values_string["contractAddress"] = contractAddress;
        values_bytes["payload"] = payload;
    }
}

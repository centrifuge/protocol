// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "test/mocks/Mock.sol";

contract MockAxelarPrecompile is Mock {
    constructor() {}

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) public {
        values_bytes32["commandId"] = commandId;
        values_string["sourceChain"] = sourceChain;
        values_string["sourceAddress"] = sourceAddress;
        values_bytes["payload"] = payload;
    }
}

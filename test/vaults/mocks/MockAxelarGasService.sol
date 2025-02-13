// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "test/mocks/Mock.sol";

contract MockAxelarGasService is Mock {
    function payNativeGasForContractCall(
        address sender,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address refundAddress
    ) external payable {
        callWithValue("payNativeGasForContractCall", msg.value);
        values_address["sender"] = sender;
        values_string["destinationChain"] = destinationChain;
        values_string["destinationAddress"] = destinationAddress;
        values_bytes["payload"] = payload;
        values_address["refundAddress"] = refundAddress;
    }
}

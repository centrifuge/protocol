// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// NOTE: This file has warning disabled due https://github.com/ethereum/solidity/issues/14359
// If perform any change on it, please ensure no other warnings appears

import {IMulticall} from "src/misc/interfaces/IMulticall.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";

abstract contract Multicall is ReentrancyProtection, IMulticall {
    function multicall(bytes[] calldata data) public payable virtual protected {
        uint256 totalBytes = data.length;
        for (uint256 i; i < totalBytes; ++i) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                uint256 length = returnData.length;
                require(length != 0, CallFailedWithEmptyRevert());

                assembly ("memory-safe") {
                    revert(add(32, returnData), length)
                }
            }
        }
    }
}

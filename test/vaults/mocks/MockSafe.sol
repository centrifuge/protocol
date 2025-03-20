// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";
import {Mock} from "test/common/mocks/Mock.sol";

contract MockSafe is Mock, ISafe {
    constructor(address[] memory owners, uint256 threshold) {
        values_uint256["threshold"] = threshold;
        for (uint256 i = 0; i < owners.length; i++) {
            addOwner(owners[i]);
        }
    }

    function addOwner(address owner) public {
        values_mapping_address_uint["owners"][owner] = 1;
    }

    function removeOwner(address owner) public {
        values_mapping_address_uint["owners"][owner] = 0;
    }

    function isOwner(address owner) public view returns (bool) {
        return values_mapping_address_uint["owners"][owner] == 1;
    }

    // Added to be ignored in coverage report
    function test() public {}
}

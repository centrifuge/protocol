// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "./Mock.sol";

interface ERC20Like {
    function transfer(address to, uint256 value) external returns (bool);
}

contract MockPoolManager is Mock {
    function transferAssets(address currency, bytes32 recipient, uint128 amount) external {
        values_address["currency"] = currency;
        values_bytes32["recipient"] = recipient;
        values_uint128["amount"] = amount;
    }

    // Added to be ignored in coverage report
    function test() public {}
}

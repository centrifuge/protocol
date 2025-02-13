// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "test/mocks/Mock.sol";
import "src/token/RestrictionManager.sol";

contract MockRestrictionManager is RestrictionManager, Mock {
    constructor(address root_, address deployer) RestrictionManager(root_, deployer) {}

    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        public
        override
        returns (bytes4)
    {
        require(checkERC20Transfer(from, to, value, hookData), "RestrictionManager/transfer-blocked");

        values_address["onERC20Transfer_from"] = from;
        values_address["onERC20Transfer_to"] = to;
        values_uint256["onERC20Transfer_value"] = value;

        return bytes4(keccak256("onERC20Transfer(address,address,uint256,(bytes16,bytes16))"));
    }
}

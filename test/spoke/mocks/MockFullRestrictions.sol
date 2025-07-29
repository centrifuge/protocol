// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../common/mocks/Mock.sol";

import {HookData} from "../../../src/common/interfaces/ITransferHook.sol";

import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";

contract MockFullRestrictions is FullRestrictions, Mock {
    constructor(
        address root_,
        address redeemSource_,
        address depositTarget_,
        address crosschainSource_,
        address deployer
    ) FullRestrictions(root_, redeemSource_, depositTarget_, crosschainSource_, deployer) {}

    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        public
        override
        returns (bytes4)
    {
        require(checkERC20Transfer(from, to, value, hookData), TransferBlocked());

        values_address["onERC20Transfer_from"] = from;
        values_address["onERC20Transfer_to"] = to;
        values_uint256["onERC20Transfer_value"] = value;

        return bytes4(keccak256("onERC20Transfer(address,address,uint256,(bytes16,bytes16))"));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HookPolicies} from "../../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../../src/token/hooks/ShareTokenHook.sol";

import {Mock} from "../../mocks/Mock.sol";

import {HookData} from "../../../../src/token/interfaces/ITransferHook.sol";

contract MockFullRestrictions is ShareTokenHook, Mock {
    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address escrowProvider_
    )
        ShareTokenHook(
            root_,
            envoy_,
            spokeRegistry_,
            spoke_,
            crosschainSource_,
            deployer,
            escrowProvider_,
            HookPolicies.fullRestrictions()
        )
    {}

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

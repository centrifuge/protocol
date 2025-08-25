// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTransferHook} from "./BaseTransferHook.sol";

import {ITransferHook, HookData} from "../common/interfaces/ITransferHook.sol";

/// @title  Freeze Only
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Supports freezing accounts which blocks transfers both to and from them
///
/// @dev    The last bit of hookData is used to denote whether the account is frozen.
contract FreezeOnly is BaseTransferHook {
    constructor(
        address root_,
        address redeemSource_,
        address depositTarget_,
        address crosschainSource_,
        address deployer
    ) BaseTransferHook(root_, redeemSource_, depositTarget_, crosschainSource_, deployer) {}

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(address from, address to, uint256, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (isSourceOrTargetFrozen(from, to, hookData)) return false;

        return true;
    }
}

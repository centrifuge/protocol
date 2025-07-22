// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITransferHook, HookData} from "src/common/interfaces/ITransferHook.sol";

import {BaseHook} from "src/hooks/BaseHook.sol";

/// @title  Freeze Only
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Supports freezing accounts which blocks transfers both to and from them
///
/// @dev    The last bit of hookData is used to denote whether the account is frozen.
contract FreezeOnly is BaseHook {
    constructor(address root_, address deployer) BaseHook(root_, deployer) {}

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

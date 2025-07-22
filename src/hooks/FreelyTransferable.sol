// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITransferHook, HookData} from "src/common/interfaces/ITransferHook.sol";

import {BaseHook} from "src/hooks/BaseHook.sol";

/// @title  Freely Transferable
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Requires accounts to be added as a member before submitting a deposit or redemption request
///         * Supports freezing accounts which blocks transfers both to and from them
contract FreelyTransferable is BaseHook {
    constructor(address root_, address deployer) BaseHook(root_, deployer) {}

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(address from, address to, uint256, /* value */ HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (isSourceOrTargetFrozen(hookData)) return false;

        if (isDepositRequest(from, to)) return isTargetMember(to, hookData);
        if (isDepositFulfillment(from, to)) return true;
        if (isDepositClaim(from, to)) return isTargetMember(to, hookData);
        if (isRedeemRequest(from, to)) return isSourceMember(from, hookData);
        if (isRedeemFulfillment(from, to)) return true;
        if (isRedeemClaim(from, to)) return true;

        // Else, it's a transfer
        return true;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTransferHook} from "./BaseTransferHook.sol";

import {ITransferHook, HookData} from "../common/interfaces/ITransferHook.sol";

/// @title  Redemption Restrictions
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Requires accounts to be added as a member before submitting a redemption request
///         * Supports freezing accounts which blocks transfers both to and from them
contract RedemptionRestrictions is BaseTransferHook {
    constructor(address root_, address spoke_, address deployer) BaseTransferHook(root_, spoke_, deployer) {}

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(address from, address to, uint256, /* value */ HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (isSourceOrTargetFrozen(from, to, hookData)) return false;
        if (isRedeemRequest(from, to)) return isSourceMember(from, hookData);
        if (isRedeemClaim(from, to)) return true;

        // Else, it's a deposit request, redemption fulfillment, or transfer
        return true;
    }
}

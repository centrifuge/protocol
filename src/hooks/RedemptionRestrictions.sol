// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITransferHook, HookData} from "src/common/interfaces/ITransferHook.sol";

import {BaseHook, TransferType} from "src/hooks/BaseHook.sol";

/// @title  Redemption Restrictions
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Requires accounts to be added as a member before submitting a redemption request
///         * Supports freezing accounts which blocks transfers both to and from them
contract RedemptionRestrictions is BaseHook {
    constructor(address root_, address spoke_, address deployer) BaseHook(root_, spoke_, deployer) {}

    /// @inheritdoc BaseHook
    function checkTransferPolicy(TransferType transferType, address from, address, /* to */ HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (transferType == TransferType.RedeemRequest || transferType == TransferType.RedeemClaim) {
            return isSourceMember(from, hookData);
        }
        return true;
    }
}

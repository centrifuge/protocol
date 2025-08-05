// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTransferHook} from "./BaseTransferHook.sol";

import {ITransferHook, HookData} from "../common/interfaces/ITransferHook.sol";

/// @title  Freely Transferable
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Requires accounts to be added as a member before submitting a deposit or redemption request
///         * Supports freezing accounts which blocks transfers both to and from them
contract FreelyTransferable is BaseTransferHook {
    constructor(
        address root_,
        address redeemSource_,
        address depositTarget_,
        address crosschainSource_,
        address deployer
    ) BaseTransferHook(root_, redeemSource_, depositTarget_, crosschainSource_, deployer) {}

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(address from, address to, uint256, /* value */ HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (isSourceOrTargetFrozen(from, to, hookData)) return false;
        if (isDepositRequest(from, to)) return isTargetMember(to, hookData);
        if (isDepositClaim(from, to)) return isTargetMember(to, hookData);
        if (isRedeemRequest(from, to)) return isSourceMember(from, hookData);
        if (isRedeemClaim(from, to)) return isSourceMember(from, hookData);

        // Else, it's a fulfillment, redemption, or transfer
        return true;
    }
}

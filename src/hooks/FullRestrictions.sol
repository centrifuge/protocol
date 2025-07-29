// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTransferHook, TransferType} from "./BaseTransferHook.sol";

import {ITransferHook, HookData} from "../common/interfaces/ITransferHook.sol";

/// @title  Full Restrictions
/// @notice Hook implementation that:
///         * Requires adding accounts to the memberlist before they can receive tokens
///         * Supports freezing accounts which blocks transfers both to and from them
contract FullRestrictions is BaseTransferHook {
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

        TransferType transferType = getTransferType(from, to);

        if (transferType == TransferType.DepositRequest) return isTargetMember(to, hookData);
        if (transferType == TransferType.DepositFulfillment) return true;
        if (transferType == TransferType.DepositClaim) return isTargetMember(to, hookData);
        if (transferType == TransferType.RedeemRequest) return isSourceMember(from, hookData);
        if (transferType == TransferType.RedeemFulfillment) return true;
        if (transferType == TransferType.RedeemClaim) return true;
        if (transferType == TransferType.CrosschainTransfer) return true;

        // Else, it's a local transfer
        return isTargetMember(to, hookData);
    }
}

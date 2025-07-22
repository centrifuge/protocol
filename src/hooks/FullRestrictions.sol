// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITransferHook, HookData} from "src/common/interfaces/ITransferHook.sol";

import {BaseHook, TransferType} from "src/hooks/BaseHook.sol";

/// @title  Full Restrictions
/// @notice Hook implementation that:
///         * Requires adding accounts to the memberlist before they can receive tokens
///         * Supports freezing accounts which blocks transfers both to and from them
contract FullRestrictions is BaseHook {
    constructor(address root_, address spoke_, address deployer) BaseHook(root_, spoke_, deployer) {}

    /// @inheritdoc BaseHook
    function checkTransferPolicy(TransferType transferType, address from, address to, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (
            transferType == TransferType.DepositFulfillment || transferType == TransferType.RedeemFulfillment
                || transferType == TransferType.CrosschainTransfer
        ) {
            return true;
        }

        if (
            transferType == TransferType.DepositRequest || transferType == TransferType.DepositClaim
                || transferType == TransferType.LocalTransfer
        ) {
            return isTargetMember(to, hookData);
        }

        if (transferType == TransferType.RedeemRequest || transferType == TransferType.RedeemClaim) {
            return isSourceMember(from, hookData);
        }

        // Unreachable fallback
        return false;
    }
}

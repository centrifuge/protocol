// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTransferHook} from "./BaseTransferHook.sol";

import {ITransferHook, HookData} from "../core/spoke/interfaces/ITransferHook.sol";

/// @title  Full Restrictions
/// @notice Hook implementation that:
///         * Requires adding accounts to the memberlist before they can receive tokens
///         * Supports freezing accounts which blocks transfers both to and from them
/// @dev    To enable cross-chain transfers to a target chain, `address(uint160(centrifugeId))`
///         must be whitelisted as a member on the source chain's share token.
contract FullRestrictions is BaseTransferHook {
    constructor(
        address root_,
        address spoke_,
        address balanceSheet_,
        address crosschainSource_,
        address deployer,
        address poolEscrowProvider_,
        address poolEscrow_
    ) BaseTransferHook(root_, spoke_, balanceSheet_, crosschainSource_, deployer, poolEscrowProvider_, poolEscrow_) {}

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(
        address from,
        address to,
        uint256,
        /* value */
        HookData calldata hookData
    )
        public
        view
        override
        returns (bool)
    {
        if (isSourceOrTargetFrozen(from, to, hookData)) return false;

        if (isDepositRequestOrIssuance(from, to)) return isTargetMember(to, hookData);
        if (isDepositFulfillment(from, to)) return true;
        if (isDepositClaim(from, to)) return isTargetMember(to, hookData);
        if (isRedeemRequest(from, to)) return isSourceMember(from, hookData);
        if (isRedeemFulfillment(from, to)) return true;
        if (isRedeemClaimOrRevocation(from, to)) return true;
        if (isCrosschainTransfer(from, to)) return true;
        if (isCrosschainTransferExecution(from, to)) return isTargetMember(to, hookData);

        // Else, it's a transfer
        return isTargetMember(to, hookData);
    }
}

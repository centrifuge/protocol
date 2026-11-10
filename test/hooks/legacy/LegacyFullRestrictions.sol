// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LegacyShareTokenHook} from "./LegacyShareTokenHook.sol";

import {VaultActionKind} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {VaultAction} from "../mocks/VaultActionCheck.sol";

import {ITransferHook, HookData} from "../../../src/token/interfaces/ITransferHook.sol";

/// @title  Full Restrictions
/// @notice Hook implementation that:
///         * Requires adding accounts to the memberlist before they can receive tokens
///         * Supports freezing accounts which blocks transfers both to and from them
/// @dev    To enable cross-chain transfers to a target chain, `address(uint160(centrifugeId))`
///         must be whitelisted as a member on the source chain's share token.
contract LegacyFullRestrictions is LegacyShareTokenHook {
    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address escrowProvider_
    ) LegacyShareTokenHook(root_, envoy_, spokeRegistry_, spoke_, crosschainSource_, deployer, escrowProvider_) {}

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

        if (isIssuance(from, to)) return isTargetMember(to, hookData);
        if (isDepositFulfillment(from, to)) return true;
        if (isDepositClaim(from, to)) return isTargetMember(to, hookData);
        if (isRedeemFulfillment(from, to)) return true;
        if (isRedeemClaimOrRevocation(from, to)) return true;
        if (isCrosschainTransfer(from, to)) return isTargetMember(to, hookData);
        if (isCrosschainTransferExecution(from, to)) return isTargetMember(to, hookData);

        // Else, it's a transfer
        return isTargetMember(to, hookData);
    }

    /// @inheritdoc LegacyShareTokenHook
    /// @dev Mirrors `checkERC20Transfer`: members (or endorsed) may request and receive, the redemption
    ///      source must be a strict member, and a lapsed holder can still claim to themselves.
    function _checkVaultAction(address token, VaultAction calldata action) internal view override returns (bool) {
        VaultActionKind kind = action.kind;

        if (kind == VaultActionKind.DepositRequest || kind == VaultActionKind.InstantDeposit) {
            return !_frozenOf(token, action.controller) && _memberOrEndorsedOf(token, action.controller);
        }
        if (kind == VaultActionKind.RedeemRequest) return _checkRedeemRequestParties(token, action);
        // The destination meets the bar of the request it takes over; the source only must be unfrozen.
        if (kind == VaultActionKind.DepositRequestTransfer) {
            return !_frozenOf(token, action.owner) && !_frozenOf(token, action.receiver)
                && _memberOrEndorsedOf(token, action.receiver);
        }
        if (kind == VaultActionKind.RedeemRequestTransfer) {
            return
                !_frozenOf(token, action.owner) && !_frozenOf(token, action.receiver)
                    && _memberOf(token, action.receiver);
        }
        if (kind == VaultActionKind.RedeemClaim) {
            if (_frozenOf(token, action.controller) || _frozenOf(token, action.receiver)) return false;
            return action.receiver == action.controller || _memberOrEndorsedOf(token, action.receiver);
        }
        if (kind == VaultActionKind.InstantRedeem) {
            if (!_checkRedeemRequestParties(token, action) || _frozenOf(token, action.receiver)) return false;
            return action.receiver == action.controller || _memberOrEndorsedOf(token, action.receiver);
        }

        return false;
    }
}

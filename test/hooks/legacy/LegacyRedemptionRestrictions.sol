// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LegacyShareTokenHook} from "./LegacyShareTokenHook.sol";

import {VaultActionKind} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {VaultAction} from "../mocks/VaultActionCheck.sol";

import {ITransferHook, HookData} from "../../../src/token/interfaces/ITransferHook.sol";

/// @title  Redemption Restrictions
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Requires accounts to be added as a member before submitting a redemption request
///         * Supports freezing accounts which blocks transfers both to and from them
contract LegacyRedemptionRestrictions is LegacyShareTokenHook {
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
        // Redemption requests have no transfer leg; they are gated as vault actions instead.
        return !isSourceOrTargetFrozen(from, to, hookData);
    }

    /// @inheritdoc LegacyShareTokenHook
    /// @dev Only redemption requests are membership-gated; everything else needs only non-frozen
    ///      parties.
    function _checkVaultAction(address token, VaultAction calldata action) internal view override returns (bool) {
        VaultActionKind kind = action.kind;

        if (kind == VaultActionKind.DepositRequest || kind == VaultActionKind.InstantDeposit) {
            return !_frozenOf(token, action.controller);
        }
        if (kind == VaultActionKind.RedeemRequest) return _checkRedeemRequestParties(token, action);
        // Only a redeem position's destination is gated: taking one on means being able to redeem.
        if (kind == VaultActionKind.DepositRequestTransfer) {
            return !_frozenOf(token, action.owner) && !_frozenOf(token, action.receiver);
        }
        if (kind == VaultActionKind.RedeemRequestTransfer) {
            return
                !_frozenOf(token, action.owner) && !_frozenOf(token, action.receiver)
                    && _memberOf(token, action.receiver);
        }
        if (kind == VaultActionKind.RedeemClaim) {
            return !_frozenOf(token, action.controller) && !_frozenOf(token, action.receiver);
        }
        if (kind == VaultActionKind.InstantRedeem) {
            return _checkRedeemRequestParties(token, action) && !_frozenOf(token, action.receiver);
        }

        return false;
    }
}

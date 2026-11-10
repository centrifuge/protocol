// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LegacyShareTokenHook} from "./LegacyShareTokenHook.sol";

import {VaultActionKind} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {VaultAction} from "../mocks/VaultActionCheck.sol";

import {ITransferHook, HookData} from "../../../src/token/interfaces/ITransferHook.sol";

/// @title  Freeze Only
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Supports freezing accounts which blocks transfers both to and from them
///
/// @dev    The last bit of hookData is used to denote whether the account is frozen.
contract LegacyFreezeOnly is LegacyShareTokenHook {
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
    function checkERC20Transfer(address from, address to, uint256, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        if (isSourceOrTargetFrozen(from, to, hookData)) return false;

        return true;
    }

    /// @inheritdoc LegacyShareTokenHook
    /// @dev No membership: any non-frozen party may request, claim, and receive.
    function _checkVaultAction(address token, VaultAction calldata action) internal view override returns (bool) {
        VaultActionKind kind = action.kind;

        if (kind == VaultActionKind.DepositRequest || kind == VaultActionKind.InstantDeposit) {
            return !_frozenOf(token, action.controller);
        }
        if (kind == VaultActionKind.RedeemRequest) {
            return !_frozenOf(token, action.owner)
                && (action.controller == action.owner || !_frozenOf(token, action.controller));
        }
        if (kind == VaultActionKind.DepositRequestTransfer || kind == VaultActionKind.RedeemRequestTransfer) {
            return !_frozenOf(token, action.owner) && !_frozenOf(token, action.receiver);
        }
        if (kind == VaultActionKind.RedeemClaim) {
            return !_frozenOf(token, action.controller) && !_frozenOf(token, action.receiver);
        }
        if (kind == VaultActionKind.InstantRedeem) {
            return !_frozenOf(token, action.owner) && !_frozenOf(token, action.controller)
                && !_frozenOf(token, action.receiver);
        }

        return false;
    }
}

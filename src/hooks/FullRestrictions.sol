// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseHook} from "src/hooks/BaseHook.sol";

/// @title  Full Restrictions
/// @notice Hook implementation that:
///         * Requires adding accounts to the memberlist before they can receive tokens
///         * Supports freezing accounts which blocks transfers both to and from them
contract FullRestrictions is BaseHook {
    constructor(address root_, address deployer) BaseHook(root_, deployer) {}

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(address from, address to, uint256, /* value */ HookData calldata hookData)
        public
        view
        returns (bool)
    {
        if (isDepositRequest(from, to) && isTargetMember(hookData)) return true;
        if (isDepositFulfillment())
        
           
        if (uint128(hookData.from).getBit(FREEZE_BIT) == true && !root.endorsed(from) && from != ESCROW_HOOK_ID) {
            // Source is frozen and not endorsed
            return false;
        }

        if (root.endorsed(to) || to == address(0) || to == ESCROW_HOOK_ID) {
            // Destination is endorsed or escrow and source was already checked, so the transfer is allowed
            return true;
        }

        uint128 toHookData = uint128(hookData.to);
        if (toHookData.getBit(FREEZE_BIT) == true) {
            // Destination is frozen
            return false;
        }

        if (toHookData >> 64 < block.timestamp) {
            // Destination is not a member
            return false;
        }

        return true;
    }
}

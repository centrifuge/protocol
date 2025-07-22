// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITransferHook, HookData} from "src/common/interfaces/ITransferHook.sol";

import {BaseHook, TransferType} from "src/hooks/BaseHook.sol";

/// @title  Freeze Only
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Supports freezing accounts which blocks transfers both to and from them
///
/// @dev    The last bit of hookData is used to denote whether the account is frozen.
contract FreezeOnly is BaseHook {
    constructor(address root_, address spoke_, address deployer) BaseHook(root_, spoke_, deployer) {}

    /// @inheritdoc BaseHook
    function checkTransferPolicy(
        TransferType, /* transferType */
        address, /* from */
        address, /* to */
        HookData calldata /* hookData */
    ) public pure override returns (bool) {
        // NOTE: FreezeOnly allows all transfers (freeze check is handled in BaseHook)
        return true;
    }
}

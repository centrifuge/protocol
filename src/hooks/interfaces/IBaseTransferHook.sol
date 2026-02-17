// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ITransferHook} from "../../core/spoke/interfaces/ITransferHook.sol";

/// @title  IBaseTransferHook
/// @notice Interface for base transfer hook with trusted call functionality
interface IBaseTransferHook is ITransferHook {
    //----------------------------------------------------------------------------------------------
    // Enums
    //----------------------------------------------------------------------------------------------

    enum TrustedCall {
        UpdateHookManager,
        RegisterPoolEscrow
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event UpdateHookManager(address indexed token, address indexed manager, bool canManage);
    event RegisterPoolEscrow(address indexed poolEscrow);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error UnknownTrustedCall();
}

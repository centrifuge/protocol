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
        UpdateHookManager
    }

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error UnknownTrustedCall();
}

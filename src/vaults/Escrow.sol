// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Auth} from "src/Auth.sol";
import {IEscrow} from "src/interfaces/IEscrow.sol";
import {IERC20} from "src/interfaces/IERC20.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";

/// @title  Escrow
/// @notice Escrow contract that holds tokens.
///         Only wards can approve funds to be taken out.
contract Escrow is Auth, IEscrow {
    constructor(address deployer) Auth(deployer) {}

    // --- Token approvals ---
    /// @inheritdoc IEscrow
    function approveMax(address token, address spender) external auth {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(token, spender, type(uint256).max);
            emit Approve(token, spender, type(uint256).max);
        }
    }

    /// @inheritdoc IEscrow
    function unapprove(address token, address spender) external auth {
        SafeTransferLib.safeApprove(token, spender, 0);
        emit Approve(token, spender, 0);
    }
}

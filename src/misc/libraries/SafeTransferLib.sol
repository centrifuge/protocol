// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {IERC7751} from "../interfaces/IERC7751.sol";

/// @title  Safe Transfer Lib
/// @author Modified from Uniswap v3 Periphery (libraries/TransferHelper.sol)
library SafeTransferLib {
    error NoCode();
    error SafeTransferFromFailed();
    error SafeTransferFailed();
    error SafeApproveFailed();
    error SafeTransferEthFailed();

    /// @notice Transfers tokens from the targeted address to the given destination
    /// @notice Errors if transfer fails
    /// @param token The contract address of the token to be transferred
    /// @param from The originating address from which the tokens will be transferred
    /// @param to The destination address of the transfer
    /// @param value The amount to be transferred
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(address(token).code.length > 0, NoCode());

        (bool success, bytes memory returnData) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        require(
            success && (returnData.length == 0 || abi.decode(returnData, (bool))),
            IERC7751.WrappedError(
                token, IERC20.transferFrom.selector, returnData, abi.encodeWithSelector(SafeTransferFromFailed.selector)
            )
        );
    }

    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Errors if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(address token, address to, uint256 value) internal {
        require(address(token).code.length > 0, NoCode());

        (bool success, bytes memory returnData) = token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        require(
            success && (returnData.length == 0 || abi.decode(returnData, (bool))),
            IERC7751.WrappedError(
                token, IERC20.transfer.selector, returnData, abi.encodeWithSelector(SafeTransferFailed.selector)
            )
        );
    }

    /// @notice Approves the stipulated contract to spend the given allowance in the given token
    /// @dev Errors if approval fails
    /// @param token The contract address of the token to be approved
    /// @param to The target of the approval
    /// @param value The amount of the given token the target will be allowed to spend
    function safeApprove(address token, address to, uint256 value) internal {
        require(address(token).code.length > 0, NoCode());

        (bool success, bytes memory returnData) = token.call(abi.encodeCall(IERC20.approve, (to, value)));
        require(
            success && (returnData.length == 0 || abi.decode(returnData, (bool))),
            IERC7751.WrappedError(
                token, IERC20.approve.selector, returnData, abi.encodeWithSelector(SafeApproveFailed.selector)
            )
        );
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @dev Make sure that method that is using this function is protected from reentrancy
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, SafeTransferEthFailed());
    }
}

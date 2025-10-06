// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRefundEscrow} from "./interfaces/IRefundEscrow.sol";

import {Auth} from "../misc/Auth.sol";

/// @title  RefundEscrow
/// @notice This contract provides a simple escrow for native token subsidies used to pay for cross-chain
///         messaging costs, allowing authorized parties to deposit funds and withdraw them to specified
///         addresses for managing transaction gas refunds.
contract RefundEscrow is Auth, IRefundEscrow {
    constructor() Auth(msg.sender) {}

    receive() external payable {}

    /// @inheritdoc IRefundEscrow
    function depositFunds() external payable auth {}

    /// @inheritdoc IRefundEscrow
    function withdrawFunds(address to, uint256 value) external auth {
        (bool success,) = to.call{value: value}("");
        require(success, CannotWithdraw());
    }
}

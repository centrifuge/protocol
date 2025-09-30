// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRefundEscrow} from "./interfaces/IRefundEscrow.sol";

import {Auth} from "../misc/Auth.sol";

contract RefundEscrow is Auth, IRefundEscrow {
    constructor(address owner) Auth(owner) {}

    receive() external payable {}

    /// @inheritdoc IRefundEscrow
    function depositFunds() external payable auth {}

    /// @inheritdoc IRefundEscrow
    function withdrawFunds(address to, uint256 value) external auth {
        (bool success,) = to.call{value: value}("");
        require(success, CannotWithdraw());
    }
}

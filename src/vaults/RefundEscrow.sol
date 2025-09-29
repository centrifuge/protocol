// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../misc/Auth.sol";

import {IRefundEscrow} from "./interfaces/IRefundEscrow.sol";

contract RefundEscrow is Auth, IRefundEscrow {
    constructor(address owner) Auth(owner) {}

    function depositFunds() external payable auth {}

    function withdrawFunds(address to, uint256 value) external auth {
        (bool success,) = to.call{value: value}("");
        require(success, CannotWithdraw());
    }
}


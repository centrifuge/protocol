// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../misc/interfaces/IERC165.sol";

interface IDepositManager is IERC165 {
    function deposit(address asset, uint256 tokenId, uint128 amount, address owner) external;
}

interface IWithdrawManager is IERC165 {
    function withdraw(address asset, uint256 tokenId, uint128 amount, address receiver) external;
}

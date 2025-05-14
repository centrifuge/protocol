// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IERC165} from "src/misc/interfaces/IERC165.sol";

interface IDepositManager is IERC165 {
    function deposit(address asset, uint256 tokenId, uint128 amount) external;
}

interface IWithdrawManager is IERC165 {
    function withdraw(address asset, uint256 tokenId, uint128 amount, address receiver) external;
}

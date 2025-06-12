// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IEscrow} from "src/misc/interfaces/IEscrow.sol";

contract Escrow is Auth, IEscrow {
    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IEscrow
    function authTransferTo(address asset, uint256 tokenId, address receiver, uint256 amount) public auth {
        if (tokenId == 0) {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            require(balance >= amount, InsufficientBalance(asset, tokenId, amount, balance));

            SafeTransferLib.safeTransfer(asset, receiver, amount);
        } else {
            uint256 balance = IERC6909(asset).balanceOf(address(this), tokenId);
            require(balance >= amount, InsufficientBalance(asset, tokenId, amount, balance));

            IERC6909(asset).transfer(receiver, tokenId, amount);
        }

        emit AuthTransferTo(asset, tokenId, receiver, amount);
    }
}

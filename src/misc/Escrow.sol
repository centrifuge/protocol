// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "./Auth.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {IERC6909} from "./interfaces/IERC6909.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

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

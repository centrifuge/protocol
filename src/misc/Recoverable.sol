// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Auth} from "./Auth.sol";
import {IERC6909} from "./interfaces/IERC6909.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {IRecoverable, ETH_ADDRESS} from "./interfaces/IRecoverable.sol";

abstract contract Recoverable is Auth, IRecoverable {
    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address receiver, uint256 amount) public auth {
        if (token == ETH_ADDRESS) {
            SafeTransferLib.safeTransferETH(receiver, amount);
        } else {
            SafeTransferLib.safeTransfer(token, receiver, amount);
        }
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) external auth {
        if (tokenId == 0) {
            recoverTokens(token, receiver, amount);
        } else {
            IERC6909(token).transfer(receiver, tokenId, amount);
        }
    }
}

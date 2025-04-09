// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

abstract contract Recoverable is Auth, IRecoverable {
    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address receiver, uint256 amount) public auth {
        if (token == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
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

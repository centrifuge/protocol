// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ITokenRecoverer} from "src/common/interfaces/ITokenRecoverer.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

contract TokenRecoverer is Auth, ITokenRecoverer {
    IRoot public immutable root;

    constructor(IRoot root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @notice inheritdoc ITokenRecoverer
    function recoverTokens(IRecoverable target, address token, uint256 tokenId, address to, uint256 amount)
        external
        auth
    {
        root.relyContract(address(target), address(this));

        if (tokenId == 0) {
            target.recoverTokens(token, to, amount);
        } else {
            target.recoverTokens(token, tokenId, to, amount);
        }

        root.denyContract(address(target), address(this));

        emit RecoverTokens(target, token, tokenId, to, amount);
    }
}

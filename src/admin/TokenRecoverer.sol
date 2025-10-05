// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "./interfaces/IRoot.sol";

import {Auth} from "../misc/Auth.sol";
import {IRecoverable} from "../misc/interfaces/IRecoverable.sol";

import {ITokenRecoverer} from "../core/messaging/interfaces/ITokenRecoverer.sol";

/// @title  TokenRecoverer
/// @notice This contract enables authorized recovery of tokens from protocol contracts by temporarily
///         granting itself permissions through Root, executing the recovery, and then immediately
///         removing those permissions.
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

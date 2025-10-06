// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../../misc/interfaces/IRecoverable.sol";

interface ITokenRecoverer {
    event RecoverTokens(
        IRecoverable indexed target, address indexed token, uint256 tokenId, address indexed to, uint256 amount
    );

    /// @notice Recovers tokens from a target contract
    /// @param target The contract to recover tokens from
    /// @param token The token address to recover
    /// @param tokenId The token ID (0 for ERC20, non-zero for ERC6909)
    /// @param to The address to send recovered tokens to
    /// @param amount The amount of tokens to recover
    function recoverTokens(IRecoverable target, address token, uint256 tokenId, address to, uint256 amount) external;
}

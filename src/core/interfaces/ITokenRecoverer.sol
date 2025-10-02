// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

interface ITokenRecoverer {
    event RecoverTokens(
        IRecoverable indexed target, address indexed token, uint256 tokenId, address indexed to, uint256 amount
    );

    function recoverTokens(IRecoverable target, address token, uint256 tokenId, address to, uint256 amount) external;
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IGateway} from "./IGateway.sol";

/// @notice Simple escrow that can be used to deposit and withdraw native tokens
interface IBatchedMulticall {
    function gateway() external view returns (IGateway);
}

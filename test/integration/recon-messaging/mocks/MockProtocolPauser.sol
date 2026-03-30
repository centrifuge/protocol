// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IProtocolPauser} from "../../../../src/core/messaging/interfaces/IProtocolPauser.sol";

contract MockProtocolPauser is IProtocolPauser {
    bool public paused;

    function setPaused(bool paused_) external {
        paused = paused_;
        if (paused_) emit Pause();
        else emit Unpause();
    }
}

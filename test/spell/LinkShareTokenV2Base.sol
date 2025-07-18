// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";

import {LinkShareTokenV2Common} from "./LinkShareTokenV2Common.sol";

/// @notice V2 Base-specific spell that transitions JTRSY share token to V3 control
/// @dev This spell runs on V2 Guardian/Root and grants v3 permissions on share tokens
contract LinkShareTokenV2Base is LinkShareTokenV2Common {
    // Base V2 Root address
    function V2_ROOT() internal pure override returns (IRoot) {
        return IRoot(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);
    }
}

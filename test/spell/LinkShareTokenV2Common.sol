// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

/// @notice V2 spell that transitions share token permissions from V2 to V3 control
/// @dev This spell runs on V2 Guardian/Root and grants v3 permissions on share tokens
abstract contract LinkShareTokenV2Common {
    bool public done;
    string public constant description = "Grant V3 Root permissions on V2 share tokens";

    // V3 addresses that need permissions on share tokens
    address public constant V3_ROOT = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;
    address public constant V3_BALANCE_SHEET = 0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda;
    address public constant V3_SPOKE = 0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B;

    // JTRSY configuration (exists on all networks)
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    // V2 Root address (network-specific)
    function V2_ROOT() internal pure virtual returns (IRoot);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        // Grant v3 permissions on JTRSY share token
        // This spell becomes ward on V2 Root, so it can call relyContract
        V2_ROOT().relyContract(address(JTRSY_SHARE_TOKEN), V3_ROOT);
        V2_ROOT().relyContract(address(JTRSY_SHARE_TOKEN), V3_BALANCE_SHEET);
        V2_ROOT().relyContract(address(JTRSY_SHARE_TOKEN), V3_SPOKE);
    }
}

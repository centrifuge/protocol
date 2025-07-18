// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {LinkShareTokenV2Common} from "./LinkShareTokenV2Common.sol";

/// @notice V2 Ethereum-specific spell that transitions both JTRSY and JAAA share tokens to V3 control
/// @dev This spell runs on V2 Guardian/Root and grants v3 permissions on share tokens
contract LinkShareTokenV2Eth is LinkShareTokenV2Common {
    // JAAA configuration (only exists on Ethereum)
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    // Ethereum V2 Root address
    function V2_ROOT() internal pure override returns (IRoot) {
        return IRoot(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);
    }

    function execute() internal override {
        // Handle JTRSY permissions (from parent)
        super.execute();

        // Handle JAAA permissions (Ethereum only)
        V2_ROOT().relyContract(address(JAAA_SHARE_TOKEN), V3_ROOT);
        V2_ROOT().relyContract(address(JAAA_SHARE_TOKEN), V3_BALANCE_SHEET);
        V2_ROOT().relyContract(address(JAAA_SHARE_TOKEN), V3_SPOKE);
    }
}

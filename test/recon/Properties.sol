// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter} from "./BeforeAfter.sol";

abstract contract Properties is BeforeAfter, Asserts {

    function property_unlockedPoolId_transient_reset() public {
        eq(_after.ghostUnlockedPoolId.raw(), 0, "unlockedPoolId not reset");
    }

    function property_debited_transient_reset() public {
        eq(_after.ghostDebited, 0, "debited not reset");
    }

    function property_credited_transient_reset() public {
        eq(_after.ghostCredited, 0, "credited not reset");
    }
}
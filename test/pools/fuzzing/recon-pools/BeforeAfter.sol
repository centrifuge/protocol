// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {PoolId} from "src/pools/types/PoolId.sol";
import {Setup} from "./Setup.sol";

// ghost variables for tracking state variable values before and after function calls
abstract contract BeforeAfter is Setup {
    struct Vars {
        PoolId ghostUnlockedPoolId;
        uint128 ghostDebited;
        uint128 ghostCredited;
    }

    Vars internal _before;
    Vars internal _after;

    modifier updateGhosts {
        __before();
        _;
        __after();
    }

    function __before() internal {
        _before.ghostUnlockedPoolId = poolRouter.unlockedPoolId();
        _before.ghostDebited = accounting.debited();
        _before.ghostCredited = accounting.credited();
    }

    function __after() internal {
        _after.ghostUnlockedPoolId = poolRouter.unlockedPoolId();
        _after.ghostDebited = accounting.debited();
        _after.ghostCredited = accounting.credited();
    }
}
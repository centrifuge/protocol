// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {ItemId} from "src/types/Domain.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {Holdings} from "src/Holdings.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";

contract TestCommon is Test {
    PoolId constant POOL_A = PoolId.wrap(42);
    IPoolRegistry immutable poolRegistry = IPoolRegistry(address(42));
    Holdings holdings = new Holdings(address(0), poolRegistry);
}

contract TestCreate is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrNonExistingPool() public {
        //TODO
    }

    function testErrWrongShareClass() public {
        //TODO
    }

    function testErrWrongValuation() public {
        //TODO
    }

    function testErrWrongAssetId() public {
        //TODO
    }
}

contract TestClose is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestIncrease is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrWrongValuation() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrWrongValuation() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testUpdateLess() public {
        //TODO
    }

    function testUpdateEquals() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestUpdateValuation is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrWrongValuation() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestSetAccountId is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

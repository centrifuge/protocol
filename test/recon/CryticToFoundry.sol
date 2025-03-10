// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {Test, console2} from "forge-std/Test.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {previewShareClassId} from "src/pools/SingleShareClass.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    function test_create_pool() public {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolManager_registerAsset(123);

        // create pool 
        poolManager_createPool(address(this), 123, singleShareClass);
    }

    function test_request_deposit() public {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolManager_registerAsset(123);

        // create pool 
        PoolId poolId = poolManager_createPool(address(this), 123, singleShareClass);

        // request deposit
        bytes32 INVESTOR = bytes32("Investor");
        ShareClassId scId = previewShareClassId(poolId);
        // TODO: create the actual share class
        poolManager_depositRequest(poolId, scId, INVESTOR, 123, 100);


    }
}
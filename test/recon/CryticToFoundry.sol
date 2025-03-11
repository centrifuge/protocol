// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {Test, console2} from "forge-std/Test.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {previewShareClassId} from "src/pools/SingleShareClass.sol";
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
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

    bytes32 INVESTOR = bytes32("Investor");
    string SC_NAME = "ExampleName";
    string SC_SYMBOL = "ExampleSymbol";
    bytes32 SC_SALT = bytes32("ExampleSalt");
    bytes32 SC_HOOK = bytes32("ExampleHookData");
    uint32 CHAIN_CV = 6;
    PoolId poolId;
    ShareClassId scId;
    AssetId assetId;
    
    function test_request_deposit() public {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolManager_registerAsset(123);

        // create pool 
        PoolId poolId = poolManager_createPool(address(this), 123, singleShareClass);

        // request deposit
        scId = previewShareClassId(poolId);
        assetId = newAssetId(123);
        
        // TODO: create the actual share class
        // (bytes[] memory cs, uint256 c) = (new bytes[](3), 0);
        // cs[c++] = abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, bytes("Testing pool"));
        // cs[c++] = abi.encodeWithSelector(poolRouter.addShareClass.selector, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
        // // TODO: figure out why these fail
        // // cs[c++] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);
        // // cs[c++] = abi.encodeWithSelector(poolRouter.notifyShareClass.selector, CHAIN_CV, scId, SC_HOOK);
        // cs[c++] = abi.encodeWithSelector(poolRouter.createHolding.selector, scId, assetId, identityValuation, 0x01);
        // poolRouter_execute(poolId, cs);

        // replacing the above with handlers that format bytes data for the poolRouter
        // necessary setup via the PoolRouter
        poolRouter_setPoolMetadata(bytes("Testing pool"));
        poolRouter_addShareClass(SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
        poolRouter_createHolding(scId, assetId, identityValuation, 0x01);
        poolRouter_execute_clamped(poolId);
        
        // request deposit
        poolManager_depositRequest(poolId, scId, INVESTOR, 123, 100);

        // claim deposit
        poolManager_claimDeposit(poolId, scId, assetId, INVESTOR);
    }

     function test_request_redeem() public {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolManager_registerAsset(123);

        // create pool 
        PoolId poolId = poolManager_createPool(address(this), 123, singleShareClass);

        // request deposit
        scId = previewShareClassId(poolId);
        assetId = newAssetId(123);

        // replacing the above with handlers that format bytes data for the poolRouter
        poolRouter_setPoolMetadata(bytes("Testing pool"));
        poolRouter_addShareClass(SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
        poolRouter_createHolding(scId, assetId, identityValuation, 0x01);

        poolRouter_execute_clamped(poolId);
        
        poolManager_depositRequest(poolId, scId, INVESTOR, 123, 100);
    }
}
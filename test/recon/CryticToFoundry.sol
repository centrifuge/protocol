// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {Test, console2} from "forge-std/Test.sol";
import {TargetFunctions} from "./TargetFunctions.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {previewShareClassId} from "src/pools/SingleShareClass.sol";
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {D18, d18} from "src/misc/types/D18.sol";

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

    uint128 constant INVESTOR_AMOUNT = 100 * 1e6; // USDC_C2
    uint128 constant SHARE_AMOUNT = 10 * 1e18; // Share from USD
    uint128 constant APPROVED_INVESTOR_AMOUNT = INVESTOR_AMOUNT / 5;
    uint128 constant APPROVED_SHARE_AMOUNT = SHARE_AMOUNT / 5;
    D18 NAV_PER_SHARE = d18(2, 1);

    PoolId poolId;
    ShareClassId scId;
    AssetId assetId;

    function _createPool() internal returns (PoolId) {
        // deploy new asset
        add_new_asset(18);

        //register asset 
        poolManager_registerAsset(123);

        // create pool 
        PoolId poolId = poolManager_createPool(address(this), 123, singleShareClass);

        return poolId;
    }
    
    function test_request_deposit() public returns (PoolId poolId, ShareClassId scId){
        poolId = _createPool();

        // request deposit
        scId = previewShareClassId(poolId);
        assetId = newAssetId(123);

        // necessary setup via the PoolRouter
        poolRouter_addShareClass(SC_NAME, SC_SYMBOL, SC_SALT, bytes(""));
        poolRouter_createHolding(scId, assetId, identityValuation, 0x01);
        poolRouter_execute_clamped(poolId);
        
        // request deposit
        poolManager_depositRequest(poolId, scId, 123, INVESTOR_AMOUNT);
        
        poolRouter_approveDeposits(scId, assetId, APPROVED_INVESTOR_AMOUNT, identityValuation);
        poolRouter_issueShares(scId, assetId, NAV_PER_SHARE);
        poolRouter_execute_clamped(poolId);

        // claim deposit
        poolManager_claimDeposit(poolId, scId, 123, INVESTOR);

        return (poolId, scId);
    }

    function test_request_redeem() public returns (PoolId poolId, ShareClassId scId){
        (poolId, scId) = test_request_deposit();

        // request redemption
        poolManager_redeemRequest(poolId, scId, 123, SHARE_AMOUNT);

        // executed via the PoolRouter
        poolRouter_approveRedeems(scId, 123, uint128(10000000));
        poolRouter_revokeShares(scId, 123, d18(10000000), identityValuation);
        poolRouter_execute_clamped(poolId);

        // claim redemption
        poolManager_claimRedeem_clamped(poolId, scId, 123);
    }

    function test_shortcut_create_pool_and_update_holding() public {
        (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_holding(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01);
    
        assetId = newAssetId(123);
        poolRouter_updateHolding(scId, assetId);
        poolRouter_execute_clamped(poolId); 
    }

    function test_shortcut_deposit_and_claim() public {
        shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_redeem_and_claim() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);
        
        shortcut_redeem_and_claim(poolId, scId, SHARE_AMOUNT, 123, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE, true);
    }

    function test_notify_share_class() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        poolRouter_notifyShareClass(CHAIN_CV, scId, SC_HOOK);
    }

    function test_shortcut_deposit_and_cancel() public {
        shortcut_deposit_and_cancel(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_redeem_and_cancel() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, NAV_PER_SHARE);

        shortcut_redeem_and_cancel(poolId, scId, SHARE_AMOUNT, 123, 50000000, NAV_PER_SHARE, true);
    }

    function test_shortcut_deposit_redeem_and_claim() public {
        shortcut_deposit_redeem_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_deposit_cancel_redemption() public {
        shortcut_deposit_cancel_redemption(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), true, 0x01, INVESTOR_AMOUNT, SHARE_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);
    }

    function test_shortcut_update_holding() public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(18, 123, SC_NAME, SC_SYMBOL, SC_SALT, bytes(""), false, 0x01, INVESTOR_AMOUNT, APPROVED_INVESTOR_AMOUNT, NAV_PER_SHARE);

        shortcut_update_holding(123, d18(20e18));
    }

}
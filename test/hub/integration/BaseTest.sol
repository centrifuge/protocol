// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";

import {MockValuation} from "../../common/mocks/MockValuation.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AccountId} from "../../../src/common/types/AccountId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {AssetId, newAssetId} from "../../../src/common/types/AssetId.sol";
import {MAX_MESSAGE_COST} from "../../../src/common/interfaces/IGasService.sol";

import {HubDeployer, HubActionBatcher, CommonInput} from "../../../script/HubDeployer.s.sol";
import {ExtendedHubDeployer, ExtendedHubActionBatcher} from "../../../script/ExtendedHubDeployer.s.sol";

import {MockVaults} from "../mocks/MockVaults.sol";

import "forge-std/Test.sol";

contract BaseTest is ExtendedHubDeployer, Test {
    uint16 constant CHAIN_CP = 5;
    uint16 constant CHAIN_CV = 6;

    string constant SC_NAME = "ExampleName";
    string constant SC_SYMBOL = "ExampleSymbol";
    bytes32 constant SC_SALT = bytes32("ExampleSalt");
    bytes32 constant SC_HOOK = bytes32("ExampleHookData");
    bool constant IS_SNAPSHOT = true;

    address immutable ADMIN = address(adminSafe);
    address immutable FM = makeAddr("FM");
    address immutable ANY = makeAddr("Anyone");
    bytes32 immutable INVESTOR = bytes32("Investor");
    address immutable ASYNC_REQUEST_MANAGER = makeAddr("AsyncRequestManager");
    address immutable SYNC_REQUEST_MANAGER = makeAddr("SyncManager");

    AssetId immutable USDC_C2 = newAssetId(CHAIN_CV, 1);
    AssetId immutable EUR_STABLE_C2 = newAssetId(CHAIN_CV, 2);

    uint128 constant INVESTOR_AMOUNT = 100 * 1e6; // USDC_C2
    uint128 constant SHARE_AMOUNT = 10 * 1e18; // Share from USD
    uint128 constant APPROVED_INVESTOR_AMOUNT = INVESTOR_AMOUNT / 5;
    uint128 constant APPROVED_SHARE_AMOUNT = SHARE_AMOUNT / 5;
    D18 immutable NAV_PER_SHARE = d18(2, 1);

    AccountId constant ASSET_USDC_ACCOUNT = AccountId.wrap(0x01);
    AccountId constant EQUITY_ACCOUNT = AccountId.wrap(0x02);
    AccountId constant LOSS_ACCOUNT = AccountId.wrap(0x03);
    AccountId constant GAIN_ACCOUNT = AccountId.wrap(0x04);
    AccountId constant ASSET_EUR_STABLE_ACCOUNT = AccountId.wrap(0x05);

    uint128 constant GAS = MAX_MESSAGE_COST;
    uint128 constant SHARE_HOOK_GAS = 0 wei;

    MockVaults cv;
    MockValuation valuation;

    function _mockStuff(HubActionBatcher batcher) private {
        vm.startPrank(address(batcher));

        cv = new MockVaults(CHAIN_CV, multiAdapter);
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = cv;
        multiAdapter.setAdapters(CHAIN_CV, PoolId.wrap(0), adapters, uint8(adapters.length), uint8(adapters.length));

        valuation = new MockValuation(hubRegistry);

        vm.stopPrank();
    }

    function setUp() public virtual {
        // Deployment
        CommonInput memory input = CommonInput({
            centrifugeId: CHAIN_CP,
            adminSafe: adminSafe,
            maxBatchGasLimit: uint128(GAS) * 100,
            version: bytes32(0)
        });

        ExtendedHubActionBatcher batcher = new ExtendedHubActionBatcher();
        labelAddresses("");
        deployExtendedHub(input, batcher);
        _mockStuff(batcher);
        removeExtendedHubDeployerAccess(batcher);

        // Initialize accounts
        vm.deal(FM, 1 ether);

        // We should not use the block ChainID
        vm.chainId(0xDEAD);
    }

    function _assertEqAccountValue(PoolId poolId, AccountId accountId, bool expectedIsPositive, uint128 expectedValue)
        internal
        view
    {
        (bool isPositive, uint128 value) = accounting.accountValue(poolId, accountId);
        assertEq(isPositive, expectedIsPositive, "Mismatch: Accounting.accountValue - isPositive");
        assertEq(value, expectedValue, "Mismatch: Accounting.accountValue - value");
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AssetId, newAssetIdFromISO4217, newAssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {D18, d18} from "src/types/D18.sol";

import {shareClassIdFor} from "src/SingleShareClass.sol";

import {AccountType} from "src/interfaces/IPoolManager.sol";

import {Deployer} from "script/Deployer.s.sol";

import {MockCentrifugeVaults} from "test/mock/MockCentrifugeVaults.sol";

import "forge-std/Test.sol";

contract TestCommon is Deployer, Test {
    uint32 constant CHAIN_1 = 1;
    uint32 constant CHAIN_2 = 2;

    address immutable DEPLOYER = makeAddr("Deployer");
    address immutable FM = makeAddr("Fund manager");
    address immutable ANY = makeAddr("Anyone without role");
    bytes32 immutable INVESTOR = bytes32(uint256(uint160(makeAddr("Investor"))));

    AssetId immutable USD = newAssetIdFromISO4217(840);
    AssetId immutable USDC_C2 = newAssetId(CHAIN_2, 1);

    MockCentrifugeVaults cv = new MockCentrifugeVaults(poolManager);

    function setUp() public {
        deploy(DEPLOYER);

        // TODO: remove this line when Gateway is implemented
        poolManager.rely(address(cv));

        // Label contracts (for debugging)
        vm.label(address(transientValuation), "TransientValuation");
        vm.label(address(oneToOneValuation), "OneToOneValuation");
        vm.label(address(multicall), "Multicall");
        vm.label(address(poolRegistry), "PoolRegistry");
        vm.label(address(assetManager), "AssetManager");
        vm.label(address(accounting), "Accounting");
        vm.label(address(holdings), "Holdings");
        vm.label(address(singleShareClass), "SingleShareClass");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(gateway), "Gateway");

        // We decide CP is located at CHAIN_1 for messaging
        vm.chainId(CHAIN_1);

        // Initial deployed configuration
        vm.prank(DEPLOYER);
        assetManager.registerAsset(USD, "United States dollar", "USD", 18);
    }
}

contract TestConfiguration is TestCommon {
    function configurePool() public returns (PoolId poolId, ShareClassId scId) {
        cv.registerAsset(USDC_C2, "USD Coin", "USDC", 6);

        vm.prank(FM);
        poolId = poolManager.createPool(USD, singleShareClass);

        scId = ShareClassId.wrap(shareClassIdFor(poolId));

        AccountId[] memory accounts = new AccountId[](4);
        accounts[0] = AccountId.wrap(0x100 | uint8(AccountType.ASSET));
        accounts[1] = AccountId.wrap(0x100 | uint8(AccountType.EQUITY));
        accounts[2] = AccountId.wrap(0x100 | uint8(AccountType.LOSS));
        accounts[3] = AccountId.wrap(0x100 | uint8(AccountType.GAIN));

        address[] memory targets = new address[](7);
        targets[0] = address(poolManager);
        targets[1] = address(poolManager);
        targets[2] = address(poolManager);
        targets[3] = address(poolManager);
        targets[4] = address(poolManager);
        targets[5] = address(poolManager);
        targets[6] = address(poolManager);
        targets[7] = address(poolManager);
        targets[8] = address(poolManager);
        targets[9] = address(poolManager);
        targets[10] = address(poolManager);
        targets[11] = address(poolManager);

        bytes[] memory methods = new bytes[](12);
        methods[0] = abi.encodeWithSelector(poolManager.setPoolMetadata.selector, bytes("Testing pool"));
        methods[1] = abi.encodeWithSelector(poolManager.addShareClass.selector, bytes(""));
        methods[2] = abi.encodeWithSelector(poolManager.notifyPool.selector, CHAIN_2);
        methods[3] = abi.encodeWithSelector(poolManager.notifyShareClass.selector, CHAIN_2, scId);
        methods[4] = abi.encodeWithSelector(poolManager.allowHoldingAsset.selector, USDC_C2, true);
        methods[5] = abi.encodeWithSelector(poolManager.createAccount.selector, accounts[0], true);
        methods[6] = abi.encodeWithSelector(poolManager.createAccount.selector, accounts[1], false);
        methods[7] = abi.encodeWithSelector(poolManager.createAccount.selector, accounts[2], false);
        methods[8] = abi.encodeWithSelector(poolManager.createAccount.selector, accounts[3], true);
        methods[9] =
            abi.encodeWithSelector(poolManager.createHolding.selector, scId, USDC_C2, oneToOneValuation, accounts);
        methods[10] = abi.encodeWithSelector(poolManager.allowInvestorAsset.selector, USDC_C2, true);
        methods[11] = abi.encodeWithSelector(poolManager.notifyAllowedAsset.selector, USDC_C2);

        vm.prank(FM);
        poolManager.execute(poolId, targets, methods);

        // From this point, pool is ready for investing from CV side
    }
}

contract TestInvesting is TestConfiguration {
    uint128 constant INVESTOR_AMOUNT = 100;
    D18 immutable PERCENT_20 = d18(1, 5);
    D18 immutable NAV_PER_SHARE = d18(2, 1);

    function baseFlow() public {
        (PoolId poolId, ShareClassId scId) = configurePool();

        cv.requestDeposit(
            poolId,
            ShareClassId.wrap(shareClassIdFor(poolId)),
            USDC_C2,
            INVESTOR,
            INVESTOR_AMOUNT ** assetManager.decimals(USDC_C2.raw())
        );

        address[] memory targets = new address[](2);
        targets[0] = address(poolManager);
        targets[1] = address(poolManager);

        bytes[] memory methods = new bytes[](2);
        methods[0] = abi.encodeWithSelector(poolManager.approveDeposits.selector, scId, USDC_C2, PERCENT_20);
        methods[1] = abi.encodeWithSelector(poolManager.issueShares.selector, scId, USDC_C2, NAV_PER_SHARE);

        vm.prank(FM);
        poolManager.execute(poolId, targets, methods);

        vm.prank(ANY);
        poolManager.claimDeposit(poolId, scId, USDC_C2, INVESTOR);
    }
}

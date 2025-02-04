// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AssetId, newAssetIdFromISO4217, newAssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {D18, d18} from "src/types/D18.sol";

import {shareClassIdFor} from "src/SingleShareClass.sol";

import {AccountType} from "src/interfaces/IPoolManager.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

import {Deployer} from "script/Deployer.s.sol";

import {MockCentrifugeVaults} from "test/mock/MockCentrifugeVaults.sol";

import "forge-std/Test.sol";

contract TestCommon is Deployer, Test {
    uint32 constant CHAIN_1 = 1;
    uint32 constant CHAIN_2 = 2;

    address immutable FM = makeAddr("FM");
    address immutable ANY = makeAddr("Anyone");
    bytes32 immutable INVESTOR = bytes32("Investor");

    AssetId immutable USDC_C2 = newAssetId(CHAIN_2, 1);

    MockCentrifugeVaults cv;

    function setUp() public {
        // Deployment
        deploy();

        cv = new MockCentrifugeVaults(poolManager);

        poolManager.rely(address(cv)); // TODO: remove this the Gateway is implemented.

        removeDeployerAccess();

        // Label contracts & actors (for debugging)
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
        vm.label(address(cv), "CV");

        // We decide CP is located at CHAIN_1 for messaging
        vm.chainId(CHAIN_1);
    }

    /// Creates a PoolMananger call
    function _createCall(bytes memory encoding) internal view returns (IMulticall.Call memory) {
        return IMulticall.Call(address(poolManager), encoding);
    }
}

contract TestConfiguration is TestCommon {
    function testBaseConfigurationPool() public returns (PoolId poolId, ShareClassId scId) {
        cv.registerAsset(USDC_C2, "USD Coin", "USDC", 6);

        vm.prank(FM);
        poolId = poolManager.createPool(USD, singleShareClass);

        scId = ShareClassId.wrap(shareClassIdFor(poolId));

        AccountId[] memory accounts = new AccountId[](4);
        accounts[0] = AccountId.wrap(0x100 | uint8(AccountType.ASSET));
        accounts[1] = AccountId.wrap(0x100 | uint8(AccountType.EQUITY));
        accounts[2] = AccountId.wrap(0x100 | uint8(AccountType.LOSS));
        accounts[3] = AccountId.wrap(0x100 | uint8(AccountType.GAIN));

        uint256 i;
        IMulticall.Call[] memory calls = new IMulticall.Call[](12);
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.setPoolMetadata.selector, bytes("Testing pool")));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.addShareClass.selector, bytes("")));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.notifyPool.selector, CHAIN_2));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.notifyShareClass.selector, CHAIN_2, scId));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.allowHoldingAsset.selector, USDC_C2, true));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[0], true));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[1], false));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[2], false));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[3], true));
        calls[i++] = _createCall(
            abi.encodeWithSelector(poolManager.createHolding.selector, scId, USDC_C2, oneToOneValuation, accounts)
        );
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.allowInvestorAsset.selector, USDC_C2, true));
        calls[i++] = _createCall(abi.encodeWithSelector(poolManager.notifyAllowedAsset.selector, scId, USDC_C2));

        assertEq(i, calls.length);

        vm.prank(FM);
        poolManager.execute(poolId, calls);

        // From this point, pool is ready for investing from CV side
    }
}

contract TestInvesting is TestConfiguration {
    uint128 constant INVESTOR_AMOUNT = 100;
    D18 immutable PERCENT_20 = d18(1, 5);
    D18 immutable NAV_PER_SHARE = d18(2, 1);

    function testBaseFlow() public {
        (PoolId poolId, ShareClassId scId) = testBaseConfigurationPool();

        cv.requestDeposit(
            poolId,
            ShareClassId.wrap(shareClassIdFor(poolId)),
            USDC_C2,
            INVESTOR,
            INVESTOR_AMOUNT ** assetManager.decimals(USDC_C2.raw())
        );

        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = _createCall(abi.encodeWithSelector(poolManager.approveDeposits.selector, scId, USDC_C2, PERCENT_20));
        calls[1] = _createCall(abi.encodeWithSelector(poolManager.issueShares.selector, scId, USDC_C2, NAV_PER_SHARE));

        vm.prank(FM);
        poolManager.execute(poolId, calls);

        vm.prank(ANY);
        poolManager.claimDeposit(poolId, scId, USDC_C2, INVESTOR);
    }
}

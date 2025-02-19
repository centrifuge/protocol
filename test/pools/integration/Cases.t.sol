// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMulticall} from "src/misc/interfaces/IMulticall.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {MessageType} from "src/common/libraries/MessageLib.sol";

import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AccountType} from "src/pools/interfaces/IPoolManager.sol";
import {previewShareClassId} from "src/pools/SingleShareClass.sol";

import {Deployer} from "script/pools/Deployer.s.sol";

import {MockVaults} from "test/pools/mocks/MockVaults.sol";

contract TestCommon is Deployer, Test {
    uint32 constant CHAIN_CP = 1;
    uint32 constant CHAIN_CV = 2;

    address immutable FM = makeAddr("FM");
    address immutable ANY = makeAddr("Anyone");
    bytes32 immutable INVESTOR = bytes32("Investor");

    AssetId immutable USDC_C2 = newAssetId(CHAIN_CV, 1);

    MockVaults cv;

    function setUp() public {
        deploy();

        // Adapting the CV mock
        cv = new MockVaults(gateway);
        gateway.file("adapter", address(cv));
        gateway.rely(address(cv));

        removeDeployerAccess();

        // Label contracts & actors (for debugging)
        vm.label(address(transientValuation), "TransientValuation");
        vm.label(address(identityValuation), "IdentityValuation");
        vm.label(address(multicall), "Multicall");
        vm.label(address(poolRegistry), "PoolRegistry");
        vm.label(address(assetRegistry), "AssetRegistry");
        vm.label(address(accounting), "Accounting");
        vm.label(address(holdings), "Holdings");
        vm.label(address(singleShareClass), "SingleShareClass");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(gateway), "Gateway");
        vm.label(address(cv), "CV");

        // We decide CP is located at CHAIN_CP for messaging
        vm.chainId(CHAIN_CP);
    }

    /// @dev Transform a list of encoding methods in PoolManager calls
    function _fromPoolManager(bytes[] memory encodedMethods) internal view returns (IMulticall.Call[] memory calls) {
        calls = new IMulticall.Call[](encodedMethods.length);

        for (uint256 i; i < encodedMethods.length; i++) {
            calls[i] = IMulticall.Call(address(poolManager), encodedMethods[i]);
        }
    }
}

contract TestConfiguration is TestCommon {
    using CastLib for string;
    using CastLib for bytes32;

    function testAssetRegistration() public {
        cv.registerAsset(USDC_C2, "USD Coin", "USDC", 6);

        (string memory name, string memory symbol, uint8 decimals) = assetRegistry.asset(USDC_C2);
        assertEq(name, "USD Coin");
        assertEq(symbol, "USDC");
        assertEq(decimals, 6);
    }

    function testPoolCreation() public returns (PoolId poolId, ShareClassId scId) {
        vm.prank(FM);
        poolId = poolManager.createPool(USD, singleShareClass);

        scId = previewShareClassId(poolId);

        (bytes[] memory cs, uint256 c) = (new bytes[](4), 0);
        cs[c++] = abi.encodeWithSelector(poolManager.setPoolMetadata.selector, bytes("Testing pool"));
        cs[c++] = abi.encodeWithSelector(poolManager.addShareClass.selector, bytes(""));
        cs[c++] = abi.encodeWithSelector(poolManager.notifyPool.selector, CHAIN_CV);
        cs[c++] = abi.encodeWithSelector(poolManager.notifyShareClass.selector, CHAIN_CV, scId);
        assertEq(c, cs.length);

        vm.prank(FM);
        poolManager.execute(poolId, _fromPoolManager(cs));

        assertEq(poolRegistry.metadata(poolId), "Testing pool");
        assertEq(cv.lastMessages(0), abi.encodePacked(MessageType.AddPool, poolId.raw()));
        assertEq(
            cv.lastMessages(1),
            abi.encodePacked(
                MessageType.AddTranche,
                poolId.raw(),
                scId,
                string("TODO").stringToBytes128(),
                string("TODO").toBytes32(),
                uint8(18),
                bytes32("TODO")
            )
        );
    }

    function testGeneralConfigurationPool() public returns (PoolId poolId, ShareClassId scId) {
        cv.registerAsset(USDC_C2, "USD Coin", "USDC", 6);

        vm.prank(FM);
        poolId = poolManager.createPool(USD, singleShareClass);

        scId = previewShareClassId(poolId);

        (bytes[] memory cs, uint256 c) = (new bytes[](5), 0);
        cs[c++] = abi.encodeWithSelector(poolManager.addShareClass.selector, bytes(""));
        cs[c++] = abi.encodeWithSelector(poolManager.notifyPool.selector, CHAIN_CV);
        cs[c++] = abi.encodeWithSelector(poolManager.notifyShareClass.selector, CHAIN_CV, scId);
        cs[c++] = abi.encodeWithSelector(poolManager.createHolding.selector, scId, USDC_C2, identityValuation, 0x01);
        cs[c++] = abi.encodeWithSelector(poolManager.allowInvestorAsset.selector, scId, USDC_C2, true);
        assertEq(c, cs.length);

        vm.prank(FM);
        poolManager.execute(poolId, _fromPoolManager(cs));

        // TODO: checks

        // From this point, pool is ready for investing from CV side
    }
}

contract TestInvestments is TestConfiguration {
    uint128 constant INVESTOR_AMOUNT = 100 * 1e18; // USDC_C2
    uint128 constant SHARE_AMOUNT = 50 * 1e6; // Share from USD
    D18 immutable PERCENT_20 = d18(1, 5);
    D18 immutable NAV_PER_SHARE = d18(2, 1);

    function testDeposit() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testGeneralConfigurationPool();

        cv.requestDeposit(poolId, scId, USDC_C2, INVESTOR, INVESTOR_AMOUNT);

        IERC7726 valuation = holdings.valuation(poolId, scId, USDC_C2);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(poolManager.approveDeposits.selector, scId, USDC_C2, PERCENT_20, valuation);
        cs[c++] = abi.encodeWithSelector(poolManager.issueShares.selector, scId, USDC_C2, NAV_PER_SHARE);
        assertEq(c, cs.length);

        vm.prank(FM);
        poolManager.execute(poolId, _fromPoolManager(cs));

        vm.prank(ANY);
        poolManager.claimDeposit(poolId, scId, USDC_C2, INVESTOR);

        // TODO: checks
        // claimed amount == SHARE_AMOUNT
    }

    function testRedeem() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testDeposit();

        cv.requestRedeem(poolId, scId, USDC_C2, INVESTOR, SHARE_AMOUNT);

        IERC7726 valuation = holdings.valuation(poolId, scId, USDC_C2);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(poolManager.approveRedeems.selector, scId, USDC_C2, PERCENT_20);
        cs[c++] = abi.encodeWithSelector(poolManager.revokeShares.selector, scId, USDC_C2, NAV_PER_SHARE, valuation);
        assertEq(c, cs.length);

        vm.prank(FM);
        poolManager.execute(poolId, _fromPoolManager(cs));

        vm.prank(ANY);
        poolManager.claimRedeem(poolId, scId, USDC_C2, INVESTOR);

        // TODO: checks
        // claimed amount == INVESTOR_AMOUNT
    }
}

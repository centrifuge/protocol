// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AssetId, newAssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {D18, d18} from "src/types/D18.sol";

import {MessageType} from "src/libraries/MessageLib.sol";
import {CastLib} from "src/libraries/CastLib.sol";

import {AccountType} from "src/interfaces/IPoolManager.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

import {shareClassIdFor} from "src/SingleShareClass.sol";

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

    /// Auxliar storage to create multicalls easily.
    IMulticall.Call[] calls; // current calls

    function setUp() public {
        deploy();

        // Adapting the CV mock
        cv = new MockCentrifugeVaults(gateway);
        gateway.file("router", address(cv));
        gateway.rely(address(cv));

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

    /// @dev Reset current calls
    function _resetCalls() internal {
        delete calls;
    }

    /// @dev Creates a PoolMananger call
    function _createCall(bytes memory encoding) internal view returns (IMulticall.Call memory) {
        return IMulticall.Call(address(poolManager), encoding);
    }
}

contract TestConfiguration is TestCommon {
    using CastLib for string;
    using CastLib for bytes32;

    function testAssetRegistration() public {
        cv.registerAsset(USDC_C2, "USD Coin", "USDC", 6);

        (string memory name, string memory symbol, uint8 decimals) = assetManager.asset(USDC_C2);
        assertEq(name, "USD Coin");
        assertEq(symbol, "USDC");
        assertEq(decimals, 6);
    }

    function testPoolCreation() public returns (PoolId poolId, ShareClassId scId) {
        vm.prank(FM);
        poolId = poolManager.createPool(USD, singleShareClass);

        scId = shareClassIdFor(poolId);

        _resetCalls();
        calls.push(_createCall(abi.encodeWithSelector(poolManager.setPoolMetadata.selector, bytes("Testing pool"))));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.addShareClass.selector, bytes(""))));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.notifyPool.selector, CHAIN_2)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.notifyShareClass.selector, CHAIN_2, scId)));

        vm.prank(FM);
        poolManager.execute(poolId, calls);

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

        scId = shareClassIdFor(poolId);

        AccountId[] memory accounts = new AccountId[](4);
        accounts[0] = AccountId.wrap(0x100 | uint8(AccountType.ASSET));
        accounts[1] = AccountId.wrap(0x100 | uint8(AccountType.EQUITY));
        accounts[2] = AccountId.wrap(0x100 | uint8(AccountType.LOSS));
        accounts[3] = AccountId.wrap(0x100 | uint8(AccountType.GAIN));

        _resetCalls();
        calls.push(_createCall(abi.encodeWithSelector(poolManager.addShareClass.selector, bytes(""))));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.notifyPool.selector, CHAIN_2)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.notifyShareClass.selector, CHAIN_2, scId)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.allowHoldingAsset.selector, USDC_C2, true)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[0], true)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[1], false)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[2], false)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.createAccount.selector, accounts[3], false)));
        calls.push(
            _createCall(
                abi.encodeWithSelector(poolManager.createHolding.selector, scId, USDC_C2, oneToOneValuation, accounts)
            )
        );
        calls.push(_createCall(abi.encodeWithSelector(poolManager.allowInvestorAsset.selector, USDC_C2, true)));
        calls.push(_createCall(abi.encodeWithSelector(poolManager.notifyAllowedAsset.selector, scId, USDC_C2)));

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
        (PoolId poolId, ShareClassId scId) = testGeneralConfigurationPool();

        cv.requestDeposit(
            poolId, shareClassIdFor(poolId), USDC_C2, INVESTOR, INVESTOR_AMOUNT ** assetManager.decimals(USDC_C2.raw())
        );

        IERC7726 valuation = holdings.valuation(poolId, scId, USDC_C2);

        _resetCalls();
        calls.push(
            _createCall(
                abi.encodeWithSelector(poolManager.approveDeposits.selector, scId, USDC_C2, PERCENT_20, valuation)
            )
        );
        calls.push(_createCall(abi.encodeWithSelector(poolManager.issueShares.selector, scId, USDC_C2, NAV_PER_SHARE)));

        vm.prank(FM);
        poolManager.execute(poolId, calls);

        vm.prank(ANY);
        poolManager.claimDeposit(poolId, scId, USDC_C2, INVESTOR);
    }
}

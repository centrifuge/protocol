// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {HubHandler} from "../../../../src/core/hub/HubHandler.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IHubHandler} from "../../../../src/core/hub/interfaces/IHubHandler.sol";
import {JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";
import {
    IBridgingHook,
    BridgeSharesParams,
    BridgeSharesResult
} from "../../../../src/core/hub/interfaces/IBridgingHook.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    uint16 constant CHAIN_A = 23;
    uint16 constant CHAIN_B = 24;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));
    AssetId constant ASSET_A = AssetId.wrap(3);
    address constant ADMIN = address(1);
    JournalEntry[] EMPTY;
    address immutable AUTH = makeAddr("auth");
    address immutable ANY = makeAddr("any");
    address immutable REFUND = makeAddr("refund");
    uint256 constant COST = 123;

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHub immutable hub = IHub(makeAddr("Hub"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    HubHandler hubHandler = new HubHandler(hub, holdings, hubRegistry, scm, AUTH);

    function setUp() public virtual {
        vm.deal(ANY, 1 ether);
    }
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthorized() public {
        vm.startPrank(ANY);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.registerAsset(AssetId.wrap(0), 0);

        bytes memory EMPTY_BYTES;
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.request(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), EMPTY_BYTES);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.updateAssets(CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), 0, false, true, 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.updateShares(CHAIN_A, PoolId.wrap(0), ShareClassId.wrap(0), 0, true, true, 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.initiateTransferShares{value: COST}(
            CHAIN_A, CHAIN_B, PoolId.wrap(0), ShareClassId.wrap(0), bytes32(""), bytes32(""), 0, 0, REFUND
        );

        vm.stopPrank();
    }
}

contract TestFile is TestCommon {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHandler.file("hub", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IHubHandler.FileUnrecognizedParam.selector);
        hubHandler.file("unknown", address(0));
    }

    function testFileHub() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("hub", address(23));
        hubHandler.file("hub", address(23));
        assertEq(address(hubHandler.hub()), address(23));
    }

    function testFileHoldings() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("holdings", address(23));
        hubHandler.file("holdings", address(23));
        assertEq(address(hubHandler.holdings()), address(23));
    }

    function testFileSender() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("sender", address(23));
        hubHandler.file("sender", address(23));
        assertEq(address(hubHandler.sender()), address(23));
    }

    function testFileShareClassmanager() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IHubHandler.File("shareClassManager", address(23));
        hubHandler.file("shareClassManager", address(23));
        assertEq(address(hubHandler.shareClassManager()), address(23));
    }
}

contract TestUpdateHoldingAmount is TestCommon {
    uint64 constant NONCE = 7;
    uint128 constant AMOUNT = 100;
    uint128 constant VALUE = 500;

    function _mockCommon(bool isInitialized) internal {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(isInitialized)
        );
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.setSnapshot.selector, POOL_A, SC_A, CHAIN_A, true, NONCE),
            abi.encode()
        );
        vm.mockCall(address(hub), abi.encodeWithSelector(IHub.updateAccountingAmount.selector), abi.encode());
    }

    function testIncreaseJournalsReturnedValue() public {
        _mockCommon(true);
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.increase.selector, POOL_A, SC_A, ASSET_A, CHAIN_A, AMOUNT),
            abi.encode(VALUE)
        );

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateAccountingAmount.selector, POOL_A, SC_A, ASSET_A, true, VALUE)
        );
        vm.expectCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.setSnapshot.selector, POOL_A, SC_A, CHAIN_A, true, NONCE)
        );

        vm.prank(AUTH);
        hubHandler.updateAssets(CHAIN_A, POOL_A, SC_A, ASSET_A, AMOUNT, true, true, NONCE);
    }

    function testDecreaseJournalsReturnedValue() public {
        _mockCommon(true);
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.decrease.selector, POOL_A, SC_A, ASSET_A, CHAIN_A, AMOUNT),
            abi.encode(VALUE)
        );

        vm.expectCall(
            address(hub),
            abi.encodeWithSelector(IHub.updateAccountingAmount.selector, POOL_A, SC_A, ASSET_A, false, VALUE)
        );

        vm.prank(AUTH);
        hubHandler.updateAssets(CHAIN_A, POOL_A, SC_A, ASSET_A, AMOUNT, false, true, NONCE);
    }

    function testUninitializedSkipsAccounting() public {
        _mockCommon(false);
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.increase.selector, POOL_A, SC_A, ASSET_A, CHAIN_A, AMOUNT),
            abi.encode(uint128(0))
        );

        vm.expectCall(address(hub), abi.encodeWithSelector(IHub.updateAccountingAmount.selector), 0);
        vm.expectCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.setSnapshot.selector, POOL_A, SC_A, CHAIN_A, true, NONCE)
        );

        vm.prank(AUTH);
        hubHandler.updateAssets(CHAIN_A, POOL_A, SC_A, ASSET_A, AMOUNT, true, true, NONCE);
    }
}

contract MockBridgingHook is IBridgingHook {
    function onBridgeShares(BridgeSharesParams calldata p) external pure returns (BridgeSharesResult memory) {
        return
            BridgeSharesResult({
                receiver: p.receiver, amount: p.amount, extraGasLimit: p.extraGasLimit, refund: p.refund
            });
    }
}

contract TestInitiateTransferSharesHook is TestCommon {
    MockBridgingHook hook;
    address immutable mockSender = makeAddr("Sender");

    function setUp() public override {
        super.setUp();
        hook = new MockBridgingHook();

        vm.prank(AUTH);
        hubHandler.file("sender", mockSender);

        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(IHubRegistry.bridgingHook.selector, POOL_A),
            abi.encode(address(hook))
        );
        vm.mockCall(address(scm), abi.encodeWithSelector(IShareClassManager.updateShares.selector), abi.encode());
        vm.mockCall(address(holdings), abi.encodeWithSelector(IHoldings.callOnTransferSnapshot.selector), abi.encode());
        vm.mockCall(
            mockSender,
            abi.encodeWithSelector(
                bytes4(
                    keccak256("sendExecuteTransferShares(uint16,uint16,uint64,bytes16,bytes32,uint128,uint128,address)")
                )
            ),
            abi.encode()
        );

        vm.deal(AUTH, 1 ether);
    }

    function testHookIsCalledAndResultForwarded() public {
        vm.prank(AUTH);
        hubHandler.initiateTransferShares{value: COST}(
            CHAIN_A, CHAIN_B, POOL_A, SC_A, bytes32("sender"), bytes32("receiver"), 100, 0, REFUND
        );
    }
}

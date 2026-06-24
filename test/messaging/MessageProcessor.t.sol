// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {newAssetId} from "../../src/core/types/AssetId.sol";
import {PoolId, newPoolId} from "../../src/core/types/PoolId.sol";
import {MessageLib} from "../../src/core/messaging/libraries/MessageLib.sol";
import {MessageProcessor} from "../../src/core/messaging/MessageProcessor.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IScheduleAuth} from "../../src/core/messaging/interfaces/IScheduleAuth.sol";
import {IMessageProcessor} from "../../src/core/messaging/interfaces/IMessageProcessor.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    address immutable ANY = makeAddr("any");
    address immutable AUTH = makeAddr("auth");

    MessageProcessor processor;
    IScheduleAuth immutable scheduleAuth = IScheduleAuth(makeAddr("ScheduleAuth"));

    function setUp() external {
        processor = new MessageProcessor(scheduleAuth, AUTH);
    }
}

contract TestSourceChecks is TestCommon {
    function testRegisterAssetOnlyFromSource() public {
        // assetId encodes centrifugeId=2, message sent from centrifugeId=1
        bytes memory message =
            MessageLib.serialize(MessageLib.RegisterAsset({assetId: newAssetId(2, 0).raw(), decimals: 18}));

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(1, message);
    }

    function testSetPoolAdaptersOnlyFromSource() public {
        // poolId encodes centrifugeId=2, message sent from centrifugeId=1
        bytes memory message = MessageLib.serialize(
            MessageLib.SetPoolAdapters({
                poolId: newPoolId(2, 0).raw(), threshold: 0, recoveryIndex: 0, adapterList: new bytes32[](0)
            })
        );

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(1, message);
    }

    function testUpdateHoldingAmountOnlyFromSource() public {
        // assetId encodes centrifugeId=2, message sent from centrifugeId=1
        bytes memory message = MessageLib.serialize(
            MessageLib.UpdateHoldingAmount({
                poolId: 0,
                scId: bytes16(0),
                assetId: newAssetId(2, 0).raw(),
                amount: 0,
                pricePoolPerAsset: 0,
                timestamp: 0,
                isIncrease: false,
                isSnapshot: false,
                nonce: 0,
                extraGasLimit: 0
            })
        );

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(1, message);
    }
}

contract TestAuthChecks is TestCommon {
    function testErrNotAuthorized() public {
        vm.startPrank(ANY);

        bytes memory EMPTY_MESSAGE;

        vm.expectRevert(IAuth.NotAuthorized.selector);
        processor.handle(1, EMPTY_MESSAGE);

        vm.stopPrank();
    }
}

contract TestFile is TestCommon {
    function testErrNotAuthorized() public {
        vm.prank(address(ANY));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        processor.file("multiAdapter", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(address(AUTH));
        vm.expectRevert(IMessageProcessor.FileUnrecognizedParam.selector);
        processor.file("unknown", address(0));
    }

    function testFileMultiAdapter() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("multiAdapter", address(23));
        processor.file("multiAdapter", address(23));
        assertEq(address(processor.multiAdapter()), address(23));
    }

    function testFileHubHandler() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("hubHandler", address(23));
        processor.file("hubHandler", address(23));
        assertEq(address(processor.hubHandler()), address(23));
    }

    function testFileGateway() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("gateway", address(23));
        processor.file("gateway", address(23));
        assertEq(address(processor.gateway()), address(23));
    }

    function testFileSpoke() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("spoke", address(23));
        processor.file("spoke", address(23));
        assertEq(address(processor.spoke()), address(23));
    }

    function testFileBalanceSheet() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("balanceSheet", address(23));
        processor.file("balanceSheet", address(23));
        assertEq(address(processor.balanceSheet()), address(23));
    }

    function testFileVaultRegistry() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("vaultRegistry", address(23));
        processor.file("vaultRegistry", address(23));
        assertEq(address(processor.vaultRegistry()), address(23));
    }

    function testFileContractUpdater() public {
        vm.prank(address(AUTH));
        vm.expectEmit();
        emit IMessageProcessor.File("contractUpdater", address(23));
        processor.file("contractUpdater", address(23));
        assertEq(address(processor.contractUpdater()), address(23));
    }
}

contract TestHandleSetPoolAdapters is TestCommon {
    using MessageLib for *;

    uint16 constant HUB_ID = 1;
    uint16 constant SPOKE_ID = 2;
    address multiAdapter = makeAddr("multiAdapter");
    PoolId poolId = newPoolId(HUB_ID, 1); // pool hubbed on HUB_ID

    function _message() internal returns (bytes memory) {
        bytes32[] memory adapters = new bytes32[](1);
        adapters[0] = bytes32(bytes20(makeAddr("adapter")));
        return MessageLib.SetPoolAdapters({poolId: poolId.raw(), threshold: 1, recoveryIndex: 0, adapterList: adapters})
            .serialize();
    }

    function _fileMultiAdapter() internal {
        vm.prank(AUTH);
        processor.file("multiAdapter", multiAdapter);
    }

    function testRevertsWhenLocalChainIsPoolHub() public {
        _fileMultiAdapter();
        // This chain hubs the pool: an inbound SetPoolAdapters for it must be rejected.
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector), abi.encode(HUB_ID));

        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.CannotSetAdaptersOnHub.selector);
        processor.handle(HUB_ID, _message()); // source == pool hub, passes OnlyFromSource
    }

    function testRevertsWhenSourceIsNotPoolHub() public {
        _fileMultiAdapter();
        vm.prank(AUTH);
        vm.expectRevert(IMessageProcessor.OnlyFromSource.selector);
        processor.handle(SPOKE_ID, _message()); // source != pool hub
    }

    function testAcceptedOnSpoke() public {
        _fileMultiAdapter();
        // Local chain is a spoke (not the pool hub) and the message comes from the hub: it is applied.
        vm.mockCall(
            multiAdapter, abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector), abi.encode(SPOKE_ID)
        );
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");

        vm.expectCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector));
        vm.prank(AUTH);
        processor.handle(HUB_ID, _message());
    }
}

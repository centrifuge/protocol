// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {IAdapterGuardian, ISafe} from "../../../src/common/interfaces/IAdapterGuardian.sol";
import {IMultiAdapter} from "../../../src/common/interfaces/IMultiAdapter.sol";
import {IHubMessageSender} from "../../../src/common/interfaces/IGatewaySenders.sol";
import {AdapterGuardian} from "../../../src/common/AdapterGuardian.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import "forge-std/Test.sol";

contract IsContract {}

contract AdapterGuardianTest is Test {
    using CastLib for address;

    ISafe immutable SAFE = ISafe(address(new IsContract()));
    IGateway immutable gateway = IGateway(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(address(new IsContract()));
    IHubMessageSender immutable sender = IHubMessageSender(address(new IsContract()));

    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable MANAGER = makeAddr("manager");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));

    uint16 constant CENTRIFUGE_ID = 1;
    PoolId constant POOL_0 = PoolId.wrap(0);

    AdapterGuardian adapterGuardian;

    function setUp() public virtual {
        adapterGuardian = new AdapterGuardian(SAFE, gateway, multiAdapter, sender);
    }

    function testAdapterGuardian() public view {
        assertEq(address(adapterGuardian.safe()), address(SAFE));
        assertEq(address(adapterGuardian.gateway()), address(gateway));
        assertEq(address(adapterGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(adapterGuardian.sender()), address(sender));
    }
}

contract AdapterGuardianTestSetAdapters is AdapterGuardianTest {
    using CastLib for address;

    function testSetAdaptersSuccess() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;
        uint8 threshold = 1;
        uint8 recoveryIndex = 2;
        address refund = makeAddr("refund");

        bytes32[] memory adapterBytes = new bytes32[](1);
        adapterBytes[0] = address(ADAPTER).toBytes32();

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, POOL_0, adapters, threshold, recoveryIndex
            ),
            abi.encode()
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(bytes4(keccak256("localCentrifugeId()"))),
            abi.encode(uint16(0))
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendSetPoolAdapters.selector,
                CENTRIFUGE_ID,
                POOL_0,
                adapterBytes,
                threshold,
                recoveryIndex,
                refund
            ),
            abi.encode()
        );
        vm.expectCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendSetPoolAdapters.selector,
                CENTRIFUGE_ID,
                POOL_0,
                adapterBytes,
                threshold,
                recoveryIndex,
                refund
            )
        );

        vm.prank(address(SAFE));
        adapterGuardian.setAdapters(CENTRIFUGE_ID, adapters, threshold, recoveryIndex, refund);
    }

    function testSetAdaptersRevertWhenNotSafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IAdapterGuardian.NotTheAuthorizedSafe.selector);
        adapterGuardian.setAdapters(CENTRIFUGE_ID, adapters, 1, 2, address(0));
    }

    function testSetAdaptersEmptyArraySuccess() public {
        IAdapter[] memory adapters = new IAdapter[](0);
        bytes32[] memory adapterBytes = new bytes32[](0);
        address refund = makeAddr("refund");

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, POOL_0, adapters, 0, 0),
            abi.encode()
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(bytes4(keccak256("localCentrifugeId()"))),
            abi.encode(uint16(0))
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendSetPoolAdapters.selector, CENTRIFUGE_ID, POOL_0, adapterBytes, 0, 0, refund
            ),
            abi.encode()
        );

        vm.prank(address(SAFE));
        adapterGuardian.setAdapters(CENTRIFUGE_ID, adapters, 0, 0, refund);
    }

    function testSetAdaptersMultipleAdaptersSuccess() public {
        IAdapter[] memory adapters = new IAdapter[](3);
        adapters[0] = IAdapter(makeAddr("adapter1"));
        adapters[1] = IAdapter(makeAddr("adapter2"));
        adapters[2] = IAdapter(makeAddr("adapter3"));
        uint8 threshold = 2;
        uint8 recoveryIndex = 2;
        address refund = makeAddr("refund");

        bytes32[] memory adapterBytes = new bytes32[](3);
        adapterBytes[0] = address(adapters[0]).toBytes32();
        adapterBytes[1] = address(adapters[1]).toBytes32();
        adapterBytes[2] = address(adapters[2]).toBytes32();

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, POOL_0, adapters, threshold, recoveryIndex
            ),
            abi.encode()
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(bytes4(keccak256("localCentrifugeId()"))),
            abi.encode(uint16(0))
        );

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                IHubMessageSender.sendSetPoolAdapters.selector,
                CENTRIFUGE_ID,
                POOL_0,
                adapterBytes,
                threshold,
                recoveryIndex,
                refund
            ),
            abi.encode()
        );

        vm.prank(address(SAFE));
        adapterGuardian.setAdapters(CENTRIFUGE_ID, adapters, threshold, recoveryIndex, refund);
    }
}

contract AdapterGuardianTestUpdateGatewayManager is AdapterGuardianTest {
    function testUpdateGatewayManagerEnableSuccess() public {
        vm.mockCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.updateManager.selector, POOL_0, MANAGER, true),
            abi.encode()
        );
        vm.expectCall(address(gateway), abi.encodeWithSelector(IGateway.updateManager.selector, POOL_0, MANAGER, true));

        vm.prank(address(SAFE));
        adapterGuardian.updateGatewayManager(MANAGER, true);
    }

    function testUpdateGatewayManagerDisableSuccess() public {
        vm.mockCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.updateManager.selector, POOL_0, MANAGER, false),
            abi.encode()
        );
        vm.expectCall(address(gateway), abi.encodeWithSelector(IGateway.updateManager.selector, POOL_0, MANAGER, false));

        vm.prank(address(SAFE));
        adapterGuardian.updateGatewayManager(MANAGER, false);
    }

    function testUpdateGatewayManagerRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IAdapterGuardian.NotTheAuthorizedSafe.selector);
        adapterGuardian.updateGatewayManager(MANAGER, true);
    }
}

contract AdapterGuardianTestBlockOutgoing is AdapterGuardianTest {
    function testBlockOutgoingBlockSuccess() public {
        vm.mockCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, POOL_0, true),
            abi.encode()
        );
        vm.expectCall(
            address(gateway), abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, POOL_0, true)
        );

        vm.prank(address(SAFE));
        adapterGuardian.blockOutgoing(CENTRIFUGE_ID, true);
    }

    function testBlockOutgoingUnblockSuccess() public {
        vm.mockCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, POOL_0, false),
            abi.encode()
        );
        vm.expectCall(
            address(gateway), abi.encodeWithSelector(IGateway.blockOutgoing.selector, CENTRIFUGE_ID, POOL_0, false)
        );

        vm.prank(address(SAFE));
        adapterGuardian.blockOutgoing(CENTRIFUGE_ID, false);
    }

    function testBlockOutgoingRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IAdapterGuardian.NotTheAuthorizedSafe.selector);
        adapterGuardian.blockOutgoing(CENTRIFUGE_ID, true);
    }
}

contract AdapterGuardianTestFile is AdapterGuardianTest {
    function testFileSafeSuccess() public {
        address newSafe = makeAddr("newSafe");

        vm.expectEmit();
        emit IAdapterGuardian.File("safe", newSafe);

        vm.prank(address(SAFE));
        adapterGuardian.file("safe", newSafe);

        assertEq(address(adapterGuardian.safe()), newSafe);
    }

    function testFileSenderSuccess() public {
        address newSender = makeAddr("newSender");

        vm.expectEmit();
        emit IAdapterGuardian.File("sender", newSender);

        vm.prank(address(SAFE));
        adapterGuardian.file("sender", newSender);

        assertEq(address(adapterGuardian.sender()), newSender);
    }

    function testFileGatewaySuccess() public {
        address newGateway = makeAddr("newGateway");

        vm.expectEmit();
        emit IAdapterGuardian.File("gateway", newGateway);

        vm.prank(address(SAFE));
        adapterGuardian.file("gateway", newGateway);

        assertEq(address(adapterGuardian.gateway()), newGateway);
    }

    function testFileMultiAdapterSuccess() public {
        address newMultiAdapter = makeAddr("newMultiAdapter");

        vm.expectEmit();
        emit IAdapterGuardian.File("multiAdapter", newMultiAdapter);

        vm.prank(address(SAFE));
        adapterGuardian.file("multiAdapter", newMultiAdapter);

        assertEq(address(adapterGuardian.multiAdapter()), newMultiAdapter);
    }

    function testFileRevertWhenUnrecognizedParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IAdapterGuardian.FileUnrecognizedParam.selector);
        adapterGuardian.file("invalid", makeAddr("address"));
    }

    function testFileRevertWhenProtocolSpecificParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IAdapterGuardian.FileUnrecognizedParam.selector);
        adapterGuardian.file("hub", makeAddr("address"));
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IAdapterGuardian.NotTheAuthorizedSafe.selector);
        adapterGuardian.file("safe", makeAddr("address"));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../../../src/admin/OpsGuardian.sol";
import {ICreatePool} from "../../../src/admin/interfaces/ICreatePool.sol";
import {IOpsGuardian} from "../../../src/admin/interfaces/IOpsGuardian.sol";
import {IBaseGuardian} from "../../../src/admin/interfaces/IBaseGuardian.sol";
import {IAdapterWiring} from "../../../src/admin/interfaces/IAdapterWiring.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract OpsGuardianTest is Test {
    ISafe immutable SAFE = ISafe(address(new IsContract()));
    ICreatePool immutable hub = ICreatePool(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(address(new IsContract()));

    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable ADMIN = makeAddr("admin");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));

    uint16 constant CENTRIFUGE_ID = 1;
    PoolId constant GLOBAL_POOL = PoolId.wrap(0);
    PoolId constant POOL_1 = PoolId.wrap(1);
    AssetId constant CURRENCY = AssetId.wrap(1);

    OpsGuardian opsGuardian;

    function setUp() public virtual {
        opsGuardian = new OpsGuardian(SAFE, hub, multiAdapter);
    }

    function testOpsGuardian() public view {
        assertEq(address(opsGuardian.opsSafe()), address(SAFE));
        assertEq(address(opsGuardian.hub()), address(hub));
        assertEq(address(opsGuardian.multiAdapter()), address(multiAdapter));
    }
}

contract OpsGuardianTestInitAdapters is OpsGuardianTest {
    function testInitAdaptersSuccess() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;
        uint8 threshold = 1;
        uint8 recoveryIndex = 2;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.quorum.selector, CENTRIFUGE_ID, GLOBAL_POOL),
            abi.encode(uint8(0))
        );

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, GLOBAL_POOL, adapters, threshold, recoveryIndex
            ),
            abi.encode()
        );

        vm.expectCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, GLOBAL_POOL, adapters, threshold, recoveryIndex
            )
        );

        vm.prank(address(SAFE));
        opsGuardian.initAdapters(CENTRIFUGE_ID, adapters, threshold, recoveryIndex);
    }

    function testInitAdaptersRevertWhenAlreadyInitialized() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.quorum.selector, CENTRIFUGE_ID, GLOBAL_POOL),
            abi.encode(uint8(1))
        );

        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.AdaptersAlreadyInitialized.selector);
        opsGuardian.initAdapters(CENTRIFUGE_ID, adapters, 1, 2);
    }

    function testInitAdaptersRevertWhenNotSafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.initAdapters(CENTRIFUGE_ID, adapters, 1, 2);
    }
}

contract OpsGuardianTestCreatePool is OpsGuardianTest {
    function testCreatePoolSuccess() public {
        vm.mockCall(
            address(hub), abi.encodeWithSelector(ICreatePool.createPool.selector, POOL_1, ADMIN, CURRENCY), abi.encode()
        );
        vm.expectCall(address(hub), abi.encodeWithSelector(ICreatePool.createPool.selector, POOL_1, ADMIN, CURRENCY));

        vm.prank(address(SAFE));
        opsGuardian.createPool(POOL_1, ADMIN, CURRENCY);
    }

    function testCreatePoolRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.createPool(POOL_1, ADMIN, CURRENCY);
    }
}

contract OpsGuardianTestFile is OpsGuardianTest {
    function testFileOpsSafeSuccess() public {
        address newOpsSafe = makeAddr("newOpsSafe");

        vm.expectEmit();
        emit IBaseGuardian.File("opsSafe", newOpsSafe);

        vm.prank(address(SAFE));
        opsGuardian.file("opsSafe", newOpsSafe);

        assertEq(address(opsGuardian.opsSafe()), newOpsSafe);
    }

    function testFileHubSuccess() public {
        address newHub = makeAddr("newHub");

        vm.expectEmit();
        emit IBaseGuardian.File("hub", newHub);

        vm.prank(address(SAFE));
        opsGuardian.file("hub", newHub);

        assertEq(address(opsGuardian.hub()), newHub);
    }

    function testFileMultiAdapterSuccess() public {
        address newMultiAdapter = makeAddr("newMultiAdapter");

        vm.expectEmit();
        emit IBaseGuardian.File("multiAdapter", newMultiAdapter);

        vm.prank(address(SAFE));
        opsGuardian.file("multiAdapter", newMultiAdapter);

        assertEq(address(opsGuardian.multiAdapter()), newMultiAdapter);
    }

    function testFileRevertWhenUnrecognizedParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IBaseGuardian.FileUnrecognizedParam.selector);
        opsGuardian.file("invalid", makeAddr("address"));
    }

    function testFileRevertWhenProtocolSpecificParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IBaseGuardian.FileUnrecognizedParam.selector);
        opsGuardian.file("gateway", makeAddr("address"));
    }

    function testFileRevertWhenSafeParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IBaseGuardian.FileUnrecognizedParam.selector);
        opsGuardian.file("safe", makeAddr("address"));
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.file("opsSafe", makeAddr("address"));
    }
}

contract OpsGuardianTestWire is OpsGuardianTest {
    function testWireSuccess() public {
        bytes memory data = abi.encode("some", "data");

        vm.mockCall(
            address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.isWired.selector, CENTRIFUGE_ID), abi.encode(false)
        );
        vm.mockCall(
            address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.wire.selector, CENTRIFUGE_ID, data), abi.encode()
        );

        vm.expectCall(address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.isWired.selector, CENTRIFUGE_ID));
        vm.expectCall(address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.wire.selector, CENTRIFUGE_ID, data));

        vm.prank(address(SAFE));
        opsGuardian.wire(address(ADAPTER), CENTRIFUGE_ID, data);
    }

    function testWireRevertWhenAlreadyWired() public {
        vm.mockCall(
            address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.isWired.selector, CENTRIFUGE_ID), abi.encode(true)
        );

        bytes memory data = abi.encode("some", "data");

        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.AdapterAlreadyWired.selector);
        opsGuardian.wire(address(ADAPTER), CENTRIFUGE_ID, data);
    }

    function testWireRevertWhenNotSafe() public {
        bytes memory data = abi.encode("some", "data");

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IBaseGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.wire(address(ADAPTER), CENTRIFUGE_ID, data);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {OpsGuardian} from "../../../src/common/OpsGuardian.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../../src/common/interfaces/IMultiAdapter.sol";
import {IOpsGuardian, ISafe} from "../../../src/common/interfaces/IOpsGuardian.sol";
import {IHubGuardianActions} from "../../../src/common/interfaces/IGuardianActions.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract OpsGuardianTest is Test {
    ISafe immutable SAFE = ISafe(address(new IsContract()));
    IHubGuardianActions immutable hub = IHubGuardianActions(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(address(new IsContract()));

    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable ADMIN = makeAddr("admin");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));

    uint16 constant CENTRIFUGE_ID = 1;
    PoolId constant POOL_0 = PoolId.wrap(0);
    PoolId constant POOL_1 = PoolId.wrap(1);
    AssetId constant CURRENCY = AssetId.wrap(1);

    OpsGuardian opsGuardian;

    function setUp() public virtual {
        opsGuardian = new OpsGuardian(SAFE, hub, multiAdapter);
    }

    function testOpsGuardian() public view {
        assertEq(address(opsGuardian.safe()), address(SAFE));
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
            abi.encodeWithSelector(IMultiAdapter.quorum.selector, CENTRIFUGE_ID, POOL_0),
            abi.encode(uint8(0))
        );

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, POOL_0, adapters, threshold, recoveryIndex
            ),
            abi.encode()
        );

        vm.expectCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, CENTRIFUGE_ID, POOL_0, adapters, threshold, recoveryIndex
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
            abi.encodeWithSelector(IMultiAdapter.quorum.selector, CENTRIFUGE_ID, POOL_0),
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
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.initAdapters(CENTRIFUGE_ID, adapters, 1, 2);
    }
}

contract OpsGuardianTestCreatePool is OpsGuardianTest {
    function testCreatePoolSuccess() public {
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(IHubGuardianActions.createPool.selector, POOL_1, ADMIN, CURRENCY),
            abi.encode()
        );
        vm.expectCall(
            address(hub), abi.encodeWithSelector(IHubGuardianActions.createPool.selector, POOL_1, ADMIN, CURRENCY)
        );

        vm.prank(address(SAFE));
        opsGuardian.createPool(POOL_1, ADMIN, CURRENCY);
    }

    function testCreatePoolRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.createPool(POOL_1, ADMIN, CURRENCY);
    }
}

contract OpsGuardianTestFile is OpsGuardianTest {
    function testFileSafeSuccess() public {
        address newSafe = makeAddr("newSafe");

        vm.expectEmit();
        emit IOpsGuardian.File("safe", newSafe);

        vm.prank(address(SAFE));
        opsGuardian.file("safe", newSafe);

        assertEq(address(opsGuardian.safe()), newSafe);
    }

    function testFileHubSuccess() public {
        address newHub = makeAddr("newHub");

        vm.expectEmit();
        emit IOpsGuardian.File("hub", newHub);

        vm.prank(address(SAFE));
        opsGuardian.file("hub", newHub);

        assertEq(address(opsGuardian.hub()), newHub);
    }

    function testFileMultiAdapterSuccess() public {
        address newMultiAdapter = makeAddr("newMultiAdapter");

        vm.expectEmit();
        emit IOpsGuardian.File("multiAdapter", newMultiAdapter);

        vm.prank(address(SAFE));
        opsGuardian.file("multiAdapter", newMultiAdapter);

        assertEq(address(opsGuardian.multiAdapter()), newMultiAdapter);
    }

    function testFileRevertWhenUnrecognizedParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.FileUnrecognizedParam.selector);
        opsGuardian.file("invalid", makeAddr("address"));
    }

    function testFileRevertWhenProtocolSpecificParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.FileUnrecognizedParam.selector);
        opsGuardian.file("gateway", makeAddr("address"));
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.file("safe", makeAddr("address"));
    }
}

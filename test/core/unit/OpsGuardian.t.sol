// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {IMultiAdapter} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../../../src/admin/OpsGuardian.sol";
import {ICreatePool} from "../../../src/admin/interfaces/ICreatePool.sol";
import {IGasService} from "../../../src/admin/interfaces/IGasService.sol";
import {IOpsGuardian} from "../../../src/admin/interfaces/IOpsGuardian.sol";
import {IAdapterWiring} from "../../../src/admin/interfaces/IAdapterWiring.sol";

import "forge-std/Test.sol";

import {ITokenBridge} from "../../../src/bridge/interfaces/ITokenBridge.sol";

contract IsContract {}

contract OpsGuardianTest is Test {
    ISafe immutable SAFE = ISafe(address(new IsContract()));
    ICreatePool immutable hub = ICreatePool(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(address(new IsContract()));
    ITokenBridge immutable tokenBridge = ITokenBridge(address(new IsContract()));

    address immutable UNAUTHORIZED = makeAddr("unauthorized");
    address immutable ADMIN = makeAddr("admin");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));

    uint16 constant CENTRIFUGE_ID = 1;
    PoolId constant GLOBAL_POOL = PoolId.wrap(0);
    PoolId constant POOL_1 = PoolId.wrap(1);
    AssetId constant CURRENCY = AssetId.wrap(1);

    OpsGuardian opsGuardian;

    function setUp() public virtual {
        opsGuardian = new OpsGuardian(SAFE, hub, tokenBridge, multiAdapter);
    }

    function testOpsGuardian() public view {
        assertEq(address(opsGuardian.opsSafe()), address(SAFE));
        assertEq(address(opsGuardian.hub()), address(hub));
        assertEq(address(opsGuardian.multiAdapter()), address(multiAdapter));
    }
}

contract OpsGuardianTestSetAdapters is OpsGuardianTest {
    // CENTRIFUGE_ID = 1 = MAINNET_CENTRIFUGE_ID (Ethereum); use a spoke chain for success cases
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;
    uint16 constant LOCAL_CENTRIFUGE_ID = 3;

    function testSetAdaptersSuccess() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;
        uint8 threshold = 1;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector),
            abi.encode(LOCAL_CENTRIFUGE_ID)
        );
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.nextActiveSessionId.selector),
            abi.encode(uint16(1))
        );

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, adapters, threshold, uint16(1)
            ),
            abi.encode()
        );

        vm.expectCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, adapters, threshold, uint16(1)
            )
        );

        vm.prank(address(SAFE));
        opsGuardian.setAdapters(REMOTE_CENTRIFUGE_ID, adapters, threshold);
    }

    function testSetAdaptersSuccessMultipleTimes() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector),
            abi.encode(LOCAL_CENTRIFUGE_ID)
        );
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.nextActiveSessionId.selector),
            abi.encode(uint16(1))
        );
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, adapters, 1, uint16(1)
            ),
            abi.encode()
        );

        vm.startPrank(address(SAFE));
        opsGuardian.setAdapters(REMOTE_CENTRIFUGE_ID, adapters, 1);
        opsGuardian.setAdapters(REMOTE_CENTRIFUGE_ID, adapters, 1);
        vm.stopPrank();
    }

    function testSetAdaptersRevertWhenLocalChain() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector),
            abi.encode(REMOTE_CENTRIFUGE_ID)
        );

        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.CannotSetAdaptersForLocalChain.selector);
        opsGuardian.setAdapters(REMOTE_CENTRIFUGE_ID, adapters, 1);
    }

    function testSetAdaptersRevertWhenHubChain() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector),
            abi.encode(LOCAL_CENTRIFUGE_ID)
        );

        uint16 mainnetId = opsGuardian.MAINNET_CENTRIFUGE_ID();
        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.CannotSetAdaptersForMainnet.selector);
        opsGuardian.setAdapters(mainnetId, adapters, 1);
    }

    function testSetAdaptersRevertWhenNotSafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.setAdapters(REMOTE_CENTRIFUGE_ID, adapters, 1);
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
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.createPool(POOL_1, ADMIN, CURRENCY);
    }
}

contract OpsGuardianTestFile is OpsGuardianTest {
    function testFileOpsSafeSuccess() public {
        address newOpsSafe = makeAddr("newOpsSafe");

        vm.expectEmit();
        emit IOpsGuardian.File("opsSafe", newOpsSafe);

        vm.prank(address(SAFE));
        opsGuardian.file("opsSafe", newOpsSafe);

        assertEq(address(opsGuardian.opsSafe()), newOpsSafe);
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

    function testFileRevertWhenSafeParam() public {
        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.FileUnrecognizedParam.selector);
        opsGuardian.file("safe", makeAddr("address"));
    }

    function testFileRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.file("opsSafe", makeAddr("address"));
    }
}

contract OpsGuardianTestSetGasService is OpsGuardianTest {
    IGasService immutable gasService = IGasService(makeAddr("gasService"));
    IGateway immutable gateway = IGateway(address(new IsContract()));

    function _mockSetGasService(address gatewayAddr) internal {
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.gateway.selector),
            abi.encode(IMessageHandler(gatewayAddr))
        );
        vm.mockCall(
            gatewayAddr,
            abi.encodeWithSelector(IGateway.file.selector, bytes32("messageProperties"), address(gasService)),
            abi.encode()
        );
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.file.selector, bytes32("messageProperties"), address(gasService)),
            abi.encode()
        );
    }

    function testSetGasServiceSuccess() public {
        _mockSetGasService(address(gateway));

        vm.expectCall(
            address(gateway),
            abi.encodeWithSelector(IGateway.file.selector, bytes32("messageProperties"), address(gasService))
        );
        vm.expectCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.file.selector, bytes32("messageProperties"), address(gasService))
        );

        vm.prank(address(SAFE));
        opsGuardian.setGasService(gasService);
    }

    function testSetGasServiceUsesCurrentGatewayFromMultiAdapter() public {
        IGateway newGateway = IGateway(address(new IsContract()));
        _mockSetGasService(address(newGateway));

        vm.expectCall(
            address(newGateway),
            abi.encodeWithSelector(IGateway.file.selector, bytes32("messageProperties"), address(gasService))
        );

        vm.prank(address(SAFE));
        opsGuardian.setGasService(gasService);
    }

    function testSetGasServiceRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.setGasService(gasService);
    }
}

contract OpsGuardianTestWire is OpsGuardianTest {
    // CENTRIFUGE_ID = 1 = MAINNET_CENTRIFUGE_ID (Ethereum); use a spoke chain for success cases
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;
    uint16 constant LOCAL_CENTRIFUGE_ID = 3;

    function _mockLocalCentrifugeId(uint16 localId) internal {
        vm.mockCall(
            address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.localCentrifugeId.selector), abi.encode(localId)
        );
    }

    function testWireSuccess() public {
        bytes memory data = abi.encode("some", "data");

        _mockLocalCentrifugeId(LOCAL_CENTRIFUGE_ID);
        vm.mockCall(
            address(ADAPTER),
            abi.encodeWithSelector(IAdapterWiring.wire.selector, REMOTE_CENTRIFUGE_ID, data),
            abi.encode()
        );

        vm.expectCall(
            address(ADAPTER), abi.encodeWithSelector(IAdapterWiring.wire.selector, REMOTE_CENTRIFUGE_ID, data)
        );

        vm.prank(address(SAFE));
        opsGuardian.wire(address(ADAPTER), REMOTE_CENTRIFUGE_ID, data);
    }

    function testWireCanBeCalledMultipleTimes() public {
        bytes memory data = abi.encode("some", "data");

        _mockLocalCentrifugeId(LOCAL_CENTRIFUGE_ID);
        vm.mockCall(
            address(ADAPTER),
            abi.encodeWithSelector(IAdapterWiring.wire.selector, REMOTE_CENTRIFUGE_ID, data),
            abi.encode()
        );

        vm.startPrank(address(SAFE));
        opsGuardian.wire(address(ADAPTER), REMOTE_CENTRIFUGE_ID, data);
        opsGuardian.wire(address(ADAPTER), REMOTE_CENTRIFUGE_ID, data);
        vm.stopPrank();
    }

    function testWireRevertWhenLocalChain() public {
        bytes memory data = abi.encode("some", "data");

        _mockLocalCentrifugeId(REMOTE_CENTRIFUGE_ID);

        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.CannotWireLocalChain.selector);
        opsGuardian.wire(address(ADAPTER), REMOTE_CENTRIFUGE_ID, data);
    }

    function testWireRevertWhenMainnet() public {
        bytes memory data = abi.encode("some", "data");

        // CENTRIFUGE_ID == 1 == MAINNET_CENTRIFUGE_ID
        assertEq(CENTRIFUGE_ID, opsGuardian.MAINNET_CENTRIFUGE_ID());

        _mockLocalCentrifugeId(LOCAL_CENTRIFUGE_ID);

        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.CannotWireMainnet.selector);
        opsGuardian.wire(address(ADAPTER), CENTRIFUGE_ID, data);
    }

    function testWireRevertWhenNotSafe() public {
        bytes memory data = abi.encode("some", "data");

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.wire(address(ADAPTER), REMOTE_CENTRIFUGE_ID, data);
    }
}

contract OpsGuardianTestBlockSession is OpsGuardianTest {
    uint16 constant SESSION_ID = 7;

    function testBlockSessionSuccess() public {
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.blockSession.selector, CENTRIFUGE_ID, GLOBAL_POOL, SESSION_ID),
            abi.encode()
        );
        vm.expectCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.blockSession.selector, CENTRIFUGE_ID, GLOBAL_POOL, SESSION_ID)
        );

        vm.prank(address(SAFE));
        opsGuardian.blockSession(CENTRIFUGE_ID, SESSION_ID);
    }

    function testBlockSessionRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.blockSession(CENTRIFUGE_ID, SESSION_ID);
    }
}

contract OpsGuardianTestTokenBridge is OpsGuardianTest {
    function testFileCentrifugeIdSuccess() public {
        uint256 evmChainId = 23;

        vm.mockCall(
            address(tokenBridge),
            abi.encodeWithSignature("chainIdToCentrifugeId(uint256)", evmChainId),
            abi.encode(uint16(0))
        );
        vm.mockCall(
            address(tokenBridge),
            abi.encodeWithSignature("file(bytes32,uint256,uint16)", bytes32("centrifugeId"), evmChainId, CENTRIFUGE_ID),
            abi.encode()
        );
        vm.expectCall(
            address(tokenBridge),
            abi.encodeWithSignature("file(bytes32,uint256,uint16)", bytes32("centrifugeId"), evmChainId, CENTRIFUGE_ID)
        );

        vm.prank(address(SAFE));
        opsGuardian.fileTokenBridgeCentrifugeId(evmChainId, CENTRIFUGE_ID);
    }

    function testFileCentrifugeIdRevertWhenAlreadySet() public {
        uint256 evmChainId = 23;

        vm.mockCall(
            address(tokenBridge),
            abi.encodeWithSignature("chainIdToCentrifugeId(uint256)", evmChainId),
            abi.encode(uint16(CENTRIFUGE_ID))
        );

        vm.prank(address(SAFE));
        vm.expectRevert(IOpsGuardian.CentrifugeIdAlreadySet.selector);
        opsGuardian.fileTokenBridgeCentrifugeId(evmChainId, CENTRIFUGE_ID);
    }

    function testFileCentrifugeIdRevertWhenNotSafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IOpsGuardian.NotTheAuthorizedSafe.selector);
        opsGuardian.fileTokenBridgeCentrifugeId(23, CENTRIFUGE_ID);
    }
}

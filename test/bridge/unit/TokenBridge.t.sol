// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {ISpokeRegistry} from "../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import "forge-std/Test.sol";

import {TokenBridge} from "../../../src/bridge/TokenBridge.sol";
import {ITokenBridge} from "../../../src/bridge/interfaces/ITokenBridge.sol";

contract IsContract {}

contract TokenBridgeTest is Test {
    uint128 constant DEFAULT_AMOUNT = 100_000_000;
    PoolId constant POOL_A = PoolId.wrap(12);
    PoolId constant POOL_B = PoolId.wrap(34);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));
    uint256 constant EVM_CHAIN_ID_1 = 1;
    uint256 constant EVM_CHAIN_ID_2 = 2031;
    uint16 constant CENTRIFUGE_ID_1 = 2;
    uint16 constant CENTRIFUGE_ID_2 = 3;
    uint16 constant LOCAL_CENTRIFUGE_ID = 7;

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address gateway = address(new IsContract());
    address shareToken1 = makeAddr("shareToken1");
    address shareToken2 = makeAddr("shareToken2");
    address envoy = makeAddr("envoy");
    address user = makeAddr("user");
    address receiver = makeAddr("receiver");
    address relayer = makeAddr("relayer");
    address unauthorized = makeAddr("unauthorized");

    TokenBridge bridge = new TokenBridge(ISpoke(spoke), IGateway(gateway), LOCAL_CENTRIFUGE_ID, envoy, address(this));

    function setUp() public virtual {
        _setupMocks();

        vm.deal(user, 1 ether);
    }

    function _setupMocks() internal {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.tokenDetails.selector, shareToken1),
            abi.encode(POOL_A, SC_1)
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.tokenDetails.selector, shareToken2),
            abi.encode(POOL_B, SC_2)
        );

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_A, SC_1),
            abi.encode(shareToken1)
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_B, SC_2),
            abi.encode(shareToken2)
        );

        vm.mockCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)"
            ),
            abi.encode()
        );

        vm.mockCall(shareToken1, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(shareToken1, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(shareToken1, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));

        vm.mockCall(shareToken2, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(shareToken2, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(shareToken2, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));

        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.isBatching.selector), abi.encode(false));
    }
}

contract TokenBridgeConstructorTest is TokenBridgeTest {
    function testConstructor() public view {
        assertEq(address(bridge.spoke()), address(spoke));
        assertEq(bridge.localCentrifugeId(), LOCAL_CENTRIFUGE_ID);
        assertEq(bridge.envoy(), envoy);
        assertEq(bridge.relayer(), address(0));
    }
}

contract TokenBridgeFileTest is TokenBridgeTest {
    function testFileRelayerSuccess() public {
        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.File("relayer", relayer);
        bridge.file("relayer", relayer);

        assertEq(bridge.relayer(), relayer);
    }

    function testFileSpokeSuccess() public {
        address newSpoke = makeAddr("newSpoke");
        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.File("spoke", newSpoke);
        bridge.file("spoke", newSpoke);

        assertEq(address(bridge.spoke()), newSpoke);
    }

    function testFileGatewaySuccess() public {
        address newGateway = makeAddr("newGateway");
        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.File("gateway", newGateway);
        bridge.file("gateway", newGateway);

        assertEq(address(bridge.gateway()), newGateway);
    }

    function testFileRelayerUnrecognizedParam() public {
        vm.expectRevert(ITokenBridge.FileUnrecognizedParam.selector);
        bridge.file("invalid", relayer);
    }

    function testFileRelayerUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        bridge.file("relayer", relayer);
    }

    function testFileChainIdSuccess() public {
        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.File("centrifugeId", EVM_CHAIN_ID_1, CENTRIFUGE_ID_1);
        bridge.file("centrifugeId", EVM_CHAIN_ID_1, CENTRIFUGE_ID_1);

        assertEq(bridge.chainIdToCentrifugeId(EVM_CHAIN_ID_1), CENTRIFUGE_ID_1);
    }

    function testFileChainIdMultiple() public {
        bridge.file("centrifugeId", EVM_CHAIN_ID_1, CENTRIFUGE_ID_1);
        bridge.file("centrifugeId", EVM_CHAIN_ID_2, CENTRIFUGE_ID_2);

        assertEq(bridge.chainIdToCentrifugeId(EVM_CHAIN_ID_1), CENTRIFUGE_ID_1);
        assertEq(bridge.chainIdToCentrifugeId(EVM_CHAIN_ID_2), CENTRIFUGE_ID_2);
    }

    function testFileChainIdUnrecognizedParam() public {
        vm.expectRevert(ITokenBridge.FileUnrecognizedParam.selector);
        bridge.file("invalid", EVM_CHAIN_ID_1, CENTRIFUGE_ID_1);
    }

    function testFileChainIdUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        bridge.file("centrifugeId", EVM_CHAIN_ID_1, CENTRIFUGE_ID_1);
    }
}

contract TokenBridgeFromHubTest is TokenBridgeTest {
    function testSetGasLimitsSuccess() public {
        uint128 extraGasLimit = 100_000;
        uint128 remoteExtraGasLimit = 200_000;

        bytes memory payload = abi.encode(SC_1.raw(), extraGasLimit, remoteExtraGasLimit);

        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.UpdateGasLimits(POOL_A, SC_1, extraGasLimit, remoteExtraGasLimit);
        vm.prank(envoy);
        bridge.fromHub(POOL_A, payload);

        (uint128 storedExtra, uint128 storedRemote) = bridge.gasLimits(POOL_A, SC_1);
        assertEq(storedExtra, extraGasLimit);
        assertEq(storedRemote, remoteExtraGasLimit);
    }

    function testSetGasLimitsMultipleShareClasses() public {
        bytes memory payload1 = abi.encode(SC_1.raw(), uint128(100_000), uint128(200_000));
        bytes memory payload2 = abi.encode(SC_2.raw(), uint128(150_000), uint128(250_000));

        vm.startPrank(envoy);
        bridge.fromHub(POOL_A, payload1);
        bridge.fromHub(POOL_B, payload2);
        vm.stopPrank();

        (uint128 extra1, uint128 remote1) = bridge.gasLimits(POOL_A, SC_1);
        (uint128 extra2, uint128 remote2) = bridge.gasLimits(POOL_B, SC_2);

        assertEq(extra1, 100_000);
        assertEq(remote1, 200_000);
        assertEq(extra2, 150_000);
        assertEq(remote2, 250_000);
    }

    function testSetGasLimitsShareTokenDoesNotExist() public {
        PoolId invalidPool = PoolId.wrap(999);
        ShareClassId invalidSc = ShareClassId.wrap(bytes16("invalid"));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, invalidPool, invalidSc),
            abi.encode(address(0))
        );

        bytes memory payload = abi.encode(invalidSc.raw(), uint128(100), uint128(200));

        vm.prank(envoy);
        vm.expectRevert(ITokenBridge.ShareTokenDoesNotExist.selector);
        bridge.fromHub(invalidPool, payload);
    }

    function testSetGasLimitsNotEnvoy() public {
        bytes memory payload = abi.encode(SC_1.raw(), uint128(100), uint128(200));

        vm.prank(unauthorized);
        vm.expectRevert(ITokenBridge.NotEnvoy.selector);
        bridge.fromHub(POOL_A, payload);
    }

    function testSetGasLimitsRejectsValue() public {
        bytes memory payload = abi.encode(SC_1.raw(), uint128(100), uint128(200));

        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(ITokenBridge.UnexpectedValue.selector);
        bridge.fromHub{value: 1}(POOL_A, payload);
    }
}

contract TokenBridgeSendTest is TokenBridgeTest {
    using CastLib for *;

    function setUp() public override {
        super.setUp();
        bridge.file("centrifugeId", EVM_CHAIN_ID_1, CENTRIFUGE_ID_1);
    }

    function testSendSuccess() public {
        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                address(this),
                address(bridge),
                DEFAULT_AMOUNT,
                0,
                0,
                user
            )
        );

        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.Send(shareToken1, address(this), EVM_CHAIN_ID_1, receiver.toBytes32(), DEFAULT_AMOUNT, user);

        bridge.send{value: 0.1 ether}(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendWithRelayer() public {
        bridge.file("relayer", relayer);

        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                address(this),
                address(bridge),
                uint128(DEFAULT_AMOUNT),
                uint128(0),
                uint128(0),
                relayer
            )
        );

        bridge.send(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendWithGasLimits() public {
        uint128 extraGasLimit = 50_000;
        uint128 remoteExtraGasLimit = 100_000;

        bytes memory payload = abi.encode(SC_1.raw(), extraGasLimit, remoteExtraGasLimit);
        vm.prank(envoy);
        bridge.fromHub(POOL_A, payload);

        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                address(this),
                address(bridge),
                uint128(DEFAULT_AMOUNT),
                extraGasLimit,
                remoteExtraGasLimit,
                user
            )
        );

        bridge.send{value: 0.1 ether}(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendSameChainRefundsUserDespiteRelayer() public {
        // A pool whose centrifugeId equals the destination: no relayer is needed for a spoke->hub leg,
        // so the overpayment is refunded directly to the user even though a relayer is configured.
        PoolId poolSameChain = PoolId.wrap((uint64(CENTRIFUGE_ID_1) << 48) | uint64(7));
        address shareToken3 = makeAddr("shareToken3");
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.tokenDetails.selector, shareToken3),
            abi.encode(poolSameChain, SC_1)
        );
        vm.mockCall(shareToken3, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(shareToken3, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(shareToken3, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));

        bridge.file("relayer", relayer);

        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                poolSameChain,
                SC_1,
                receiver.toBytes32(),
                address(this),
                address(bridge),
                uint128(DEFAULT_AMOUNT),
                uint128(0),
                uint128(0),
                user
            )
        );

        bridge.send(shareToken3, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendSourceHubRefundsUserDespiteRelayer() public {
        // A pool whose centrifugeId equals this chain's (the source is the hub): a hub->spoke transfer is a
        // single leg, so the overpayment is refunded directly to the user even though a relayer is configured
        // and the destination is a remote spoke.
        PoolId poolSourceHub = PoolId.wrap((uint64(LOCAL_CENTRIFUGE_ID) << 48) | uint64(7));
        address shareToken3 = makeAddr("shareToken3");
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.tokenDetails.selector, shareToken3),
            abi.encode(poolSourceHub, SC_1)
        );
        vm.mockCall(shareToken3, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(shareToken3, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(shareToken3, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));

        bridge.file("relayer", relayer);

        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,address,address,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                poolSourceHub,
                SC_1,
                receiver.toBytes32(),
                address(this),
                address(bridge),
                uint128(DEFAULT_AMOUNT),
                uint128(0),
                uint128(0),
                user
            )
        );

        bridge.send(shareToken3, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendWhileBatching() public {
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.isBatching.selector), abi.encode(true));

        vm.expectRevert(ITokenBridge.NotBatchable.selector);
        bridge.send{value: 0.1 ether}(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendInvalidChainId() public {
        uint256 invalidChainId = 999;

        vm.expectRevert(ITokenBridge.InvalidChainId.selector);
        bridge.send(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), invalidChainId, user);
    }

    function testSendInvalidToken() public {
        address invalidToken = makeAddr("invalidToken");

        // The token backs no share class, so tokenDetails resolves to a null pool id and send fails closed
        // before pulling any tokens.
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.tokenDetails.selector, invalidToken),
            abi.encode(PoolId.wrap(0), ShareClassId.wrap(bytes16(0)))
        );

        vm.expectRevert(ITokenBridge.ShareTokenDoesNotExist.selector);
        bridge.send(invalidToken, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

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

    address spoke = address(new IsContract());
    address shareToken1 = makeAddr("shareToken1");
    address shareToken2 = makeAddr("shareToken2");
    address user = makeAddr("user");
    address receiver = makeAddr("receiver");
    address relayer = makeAddr("relayer");
    address unauthorized = makeAddr("unauthorized");

    TokenBridge bridge = new TokenBridge(ISpoke(spoke), address(this));

    function setUp() public virtual {
        _setupMocks();

        vm.deal(user, 1 ether);
    }

    function _setupMocks() internal {
        vm.mockCall(
            spoke, abi.encodeWithSelector(ISpoke.shareTokenDetails.selector, shareToken1), abi.encode(POOL_A, SC_1)
        );
        vm.mockCall(
            spoke, abi.encodeWithSelector(ISpoke.shareTokenDetails.selector, shareToken2), abi.encode(POOL_B, SC_2)
        );

        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.shareToken.selector, POOL_A, SC_1), abi.encode(shareToken1));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.shareToken.selector, POOL_B, SC_2), abi.encode(shareToken2));

        vm.mockCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)"
            ),
            abi.encode()
        );

        vm.mockCall(shareToken1, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(shareToken1, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(shareToken1, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));

        vm.mockCall(shareToken2, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(shareToken2, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(shareToken2, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));
    }
}

contract TokenBridgeConstructorTest is TokenBridgeTest {
    function testConstructor() public view {
        assertEq(address(bridge.spoke()), address(spoke));
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

contract TokenBridgeTrustedCallTest is TokenBridgeTest {
    function testSetGasLimitsSuccess() public {
        uint128 extraGasLimit = 100_000;
        uint128 remoteExtraGasLimit = 200_000;

        bytes memory payload =
            abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), extraGasLimit, remoteExtraGasLimit);

        vm.expectEmit(true, true, true, true);
        emit ITokenBridge.UpdateGasLimits(POOL_A, SC_1, extraGasLimit, remoteExtraGasLimit);
        bridge.trustedCall(POOL_A, SC_1, payload);

        (uint128 storedExtra, uint128 storedRemote) = bridge.gasLimits(POOL_A, SC_1);
        assertEq(storedExtra, extraGasLimit);
        assertEq(storedRemote, remoteExtraGasLimit);
    }

    function testSetGasLimitsMultipleShareClasses() public {
        bytes memory payload1 =
            abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), uint128(100_000), uint128(200_000));
        bytes memory payload2 =
            abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), uint128(150_000), uint128(250_000));

        bridge.trustedCall(POOL_A, SC_1, payload1);
        bridge.trustedCall(POOL_B, SC_2, payload2);

        (uint128 extra1, uint128 remote1) = bridge.gasLimits(POOL_A, SC_1);
        (uint128 extra2, uint128 remote2) = bridge.gasLimits(POOL_B, SC_2);

        assertEq(extra1, 100_000);
        assertEq(remote1, 200_000);
        assertEq(extra2, 150_000);
        assertEq(remote2, 250_000);
    }

    function testSetGasLimitsUnknownTrustedCall() public {
        bytes memory payload = abi.encode(uint8(99));

        vm.expectRevert(ITokenBridge.UnknownTrustedCall.selector);
        bridge.trustedCall(POOL_A, SC_1, payload);
    }

    function testSetGasLimitsShareTokenDoesNotExist() public {
        PoolId invalidPool = PoolId.wrap(999);
        ShareClassId invalidSc = ShareClassId.wrap(bytes16("invalid"));

        vm.mockCall(
            spoke, abi.encodeWithSelector(ISpoke.shareToken.selector, invalidPool, invalidSc), abi.encode(address(0))
        );

        bytes memory payload = abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), uint128(100), uint128(200));

        vm.expectRevert(ITokenBridge.ShareTokenDoesNotExist.selector);
        bridge.trustedCall(invalidPool, invalidSc, payload);
    }

    function testSetGasLimitsUnauthorized() public {
        bytes memory payload = abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), uint128(100), uint128(200));

        vm.prank(unauthorized);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        bridge.trustedCall(POOL_A, SC_1, payload);
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
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                DEFAULT_AMOUNT,
                0,
                0,
                user
            )
        );

        bridge.send{value: 0.1 ether}(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendWithRelayer() public {
        bridge.file("relayer", relayer);

        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
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

        bytes memory payload =
            abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), extraGasLimit, remoteExtraGasLimit);
        bridge.trustedCall(POOL_A, SC_1, payload);

        vm.expectCall(
            spoke,
            abi.encodeWithSignature(
                "crosschainTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_1,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                uint128(DEFAULT_AMOUNT),
                extraGasLimit,
                remoteExtraGasLimit,
                user
            )
        );

        bridge.send{value: 0.1 ether}(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendInvalidChainId() public {
        uint256 invalidChainId = 999;

        vm.expectRevert(ITokenBridge.InvalidChainId.selector);
        bridge.send(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), invalidChainId, user);
    }

    function testSendInvalidToken() public {
        address invalidToken = makeAddr("invalidToken");

        vm.mockCall(invalidToken, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(invalidToken, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(invalidToken, abi.encodeWithSelector(IERC20.allowance.selector), abi.encode(0));

        vm.mockCallRevert(
            spoke,
            abi.encodeWithSelector(ISpoke.shareTokenDetails.selector, invalidToken),
            abi.encodeWithSelector(ISpoke.ShareTokenDoesNotExist.selector)
        );

        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        bridge.send(invalidToken, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user);
    }

    function testSendWithOutputToken() public {
        bytes32 outputToken = bytes32(uint256(uint160(makeAddr("outputToken"))));

        bridge.send{
            value: 0.1 ether
        }(shareToken1, DEFAULT_AMOUNT, receiver.toBytes32(), EVM_CHAIN_ID_1, user, outputToken);
    }
}

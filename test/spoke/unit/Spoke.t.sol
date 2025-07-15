// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ISpokeMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IPoolEscrowFactory} from "src/common/factories/interfaces/IPoolEscrowFactory.sol";

import {ITokenFactory} from "src/spoke/factories/interfaces/ITokenFactory.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {Spoke, ISpoke} from "src/spoke/Spoke.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");

    ITokenFactory tokenFactory = ITokenFactory(makeAddr("tokenFactory"));
    IPoolEscrowFactory poolEscrowFactory = IPoolEscrowFactory(makeAddr("poolEscrowFactory"));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    IGateway gateway = IGateway(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    AssetId constant ASSET_ID_20 = AssetId.wrap(3);
    AssetId constant ASSET_ID_6909_1 = AssetId.wrap(4);
    uint16 constant INITIAL_GAS = 1000;
    uint16 constant GAS = 100;

    Spoke spoke = new Spoke(tokenFactory, AUTH);

    function setUp() public {
        vm.deal(ANY, INITIAL_GAS);

        vm.startPrank(AUTH);
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(sender));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));

        vm.stopPrank();
    }

    function testConstructor() public view {
        assertEq(address(spoke.tokenFactory()), address(tokenFactory));
    }

    function _mockPayment(address who) public {
        vm.mockCall(
            address(gateway), GAS, abi.encodeWithSelector(gateway.startTransactionPayment.selector, who), abi.encode()
        );

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endTransactionPayment.selector), abi.encode());
    }
}

contract SpokeTestFile is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.file("unknown", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.FileUnrecognizedParam.selector);
        spoke.file("unknown", address(1));
    }

    function testGatewayFile() public {
        vm.startPrank(AUTH);
        vm.expectEmit();
        emit ISpoke.File("gateway", address(23));
        spoke.file("gateway", address(23));
        assertEq(address(spoke.gateway()), address(23));

        spoke.file("sender", address(42));
        assertEq(address(spoke.sender()), address(42));

        spoke.file("tokenFactory", address(88));
        assertEq(address(spoke.tokenFactory()), address(88));

        spoke.file("poolEscrowFactory", address(99));
        assertEq(address(spoke.poolEscrowFactory()), address(99));
    }
}

contract SpokeTestCrosschainTransferShares is SpokeTest {
    using CastLib for *;

    function testErrLocalTransferNotAllowed() public {
        vm.prank(AUTH);
        spoke.linkToken(POOL_A, SC_1, share);

        _mockPayment(ANY);
        vm.mockCall(
            address(sender), abi.encodeWithSelector(sender.localCentrifugeId.selector), abi.encode(LOCAL_CENTRIFUGE_ID)
        );

        vm.prank(ANY);
        vm.expectRevert(ISpoke.LocalTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: GAS}(LOCAL_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), 100, 0);
    }
}

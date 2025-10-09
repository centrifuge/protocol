// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {CCIPAdapter} from "../../../src/adapters/CCIPAdapter.sol";
import {
    ICCIPAdapter,
    IAdapter,
    CCIPSource,
    CCIPDestination,
    IRouterClient,
    IClient,
    EVM_EXTRA_ARGS_V1_TAG,
    IAny2EVMMessageReceiver
} from "../../../src/adapters/interfaces/ICCIPAdapter.sol";

contract MockCCIPRouter is Mock {
    function isChainSupported(uint64 chainSelector) external pure returns (bool) {
        return chainSelector != 0;
    }

    function ccipSend(uint64 destinationChainSelector, IClient.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId)
    {
        values_uint256["value"] = msg.value;
        values_uint64["destinationChainSelector"] = destinationChainSelector;
        values_bytes["receiver"] = message.receiver;
        values_bytes["data"] = message.data;
        values_address["feeToken"] = message.feeToken;
        values_bytes["extraArgs"] = message.extraArgs;

        return bytes32(uint256(123));
    }

    function getFee(uint64, IClient.EVM2AnyMessage calldata) external pure returns (uint256) {
        return 200_000;
    }
}

contract CCIPAdapterTestBase is Test {
    MockCCIPRouter ccipRouter;
    CCIPAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint64 constant CCIP_CHAIN_SELECTOR = 2;
    address immutable REMOTE_CCIP_ADDR = makeAddr("remoteAddress");

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        ccipRouter = new MockCCIPRouter();
        adapter = new CCIPAdapter(GATEWAY, address(ccipRouter), address(this));
    }
}

contract CCIPAdapterTestWire is CCIPAdapterTestBase {
    using CastLib for *;

    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCIP_CHAIN_SELECTOR, REMOTE_CCIP_ADDR));
    }

    function testWire() public {
        vm.expectEmit();
        emit ICCIPAdapter.Wire(CENTRIFUGE_ID, CCIP_CHAIN_SELECTOR, REMOTE_CCIP_ADDR);
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCIP_CHAIN_SELECTOR, REMOTE_CCIP_ADDR));

        (uint16 centrifugeId, address addr) = adapter.sources(CCIP_CHAIN_SELECTOR);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(addr, REMOTE_CCIP_ADDR);

        (uint64 chainSelector, address addr2) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(chainSelector, CCIP_CHAIN_SELECTOR);
        assertEq(addr2, REMOTE_CCIP_ADDR);
    }

    function testIsWired() public {
        assertFalse(adapter.isWired(CENTRIFUGE_ID));
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCIP_CHAIN_SELECTOR, REMOTE_CCIP_ADDR));
        assertTrue(adapter.isWired(CENTRIFUGE_ID));
    }
}

contract CCIPAdapterTest is CCIPAdapterTestBase {
    using CastLib for *;

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.ccipRouter()), address(ccipRouter));

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimateCCIP(uint64 gasLimit) public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(CCIP_CHAIN_SELECTOR, REMOTE_CCIP_ADDR));

        bytes memory payload = "irrelevant";
        assertEq(adapter.estimate(CENTRIFUGE_ID, payload, gasLimit), 200_000);
    }

    function testIncomingCalls(
        bytes memory payload,
        address validAddress,
        address invalidAddress,
        uint64 invalidChainSelector,
        address invalidOrigin
    ) public {
        vm.assume(keccak256(abi.encodePacked(invalidAddress)) != keccak256(abi.encodePacked(validAddress)));
        vm.assume(invalidChainSelector != CCIP_CHAIN_SELECTOR);
        vm.assume(invalidOrigin != address(ccipRouter));
        assumeNotZeroAddress(validAddress);
        assumeNotZeroAddress(invalidAddress);

        vm.mockCall(
            address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload), abi.encode()
        );

        IClient.Any2EVMMessage memory message = IClient.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: CCIP_CHAIN_SELECTOR,
            sender: abi.encode(validAddress),
            data: payload,
            destTokenAmounts: new IClient.EVMTokenAmount[](0)
        });

        // Correct input, but not yet setup
        vm.prank(address(ccipRouter));
        vm.expectRevert(ICCIPAdapter.InvalidSourceChain.selector);
        adapter.ccipReceive(message);

        adapter.wire(CENTRIFUGE_ID, abi.encode(CCIP_CHAIN_SELECTOR, validAddress));

        // Incorrect address
        message.sender = abi.encode(invalidAddress);
        vm.prank(address(ccipRouter));
        vm.expectRevert(ICCIPAdapter.InvalidSourceAddress.selector);
        adapter.ccipReceive(message);

        // Correct sender, but from invalid chain
        message.sender = abi.encode(validAddress);
        message.sourceChainSelector = invalidChainSelector;
        vm.prank(address(ccipRouter));
        vm.expectRevert(ICCIPAdapter.InvalidSourceChain.selector);
        adapter.ccipReceive(message);

        // Correct message, but incorrect caller
        message.sourceChainSelector = CCIP_CHAIN_SELECTOR;
        vm.prank(invalidOrigin);
        vm.expectRevert(ICCIPAdapter.InvalidRouter.selector);
        adapter.ccipReceive(message);

        // Correct
        vm.prank(address(ccipRouter));
        adapter.ccipReceive(message);
    }

    function testOutgoingCalls(bytes calldata payload, address invalidOrigin, uint256 gasLimit, address refund)
        public
    {
        vm.assume(gasLimit < adapter.RECEIVE_COST());
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.deal(address(this), 0.1 ether);
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        adapter.wire(CENTRIFUGE_ID, abi.encode(CCIP_CHAIN_SELECTOR, makeAddr("DestinationAdapter")));

        vm.deal(address(this), 0.1 ether);
        vm.prank(address(GATEWAY));
        bytes32 messageId = adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        assertEq(messageId, bytes32(uint256(123)));
        assertEq(ccipRouter.values_uint256("value"), 0.1 ether);
        assertEq(ccipRouter.values_uint64("destinationChainSelector"), CCIP_CHAIN_SELECTOR);
        assertEq(ccipRouter.values_bytes("receiver"), abi.encode(makeAddr("DestinationAdapter")));
        assertEq(ccipRouter.values_bytes("data"), payload);
        assertEq(ccipRouter.values_address("feeToken"), address(0)); // Native token

        // Verify extraArgs contain the gas limit
        bytes memory expectedExtraArgs = abi.encodeWithSelector(
            EVM_EXTRA_ARGS_V1_TAG, IClient.EVMExtraArgsV1({gasLimit: gasLimit + adapter.RECEIVE_COST()})
        );
        assertEq(ccipRouter.values_bytes("extraArgs"), expectedExtraArgs);
    }

    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 any2EVMMessageReceiver = 0x85572ffb;

        vm.assume(unsupportedInterfaceId != erc165 && unsupportedInterfaceId != any2EVMMessageReceiver);

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IAny2EVMMessageReceiver).interfaceId, any2EVMMessageReceiver);

        assertEq(adapter.supportsInterface(erc165), true);
        assertEq(adapter.supportsInterface(any2EVMMessageReceiver), true);

        assertEq(adapter.supportsInterface(unsupportedInterfaceId), false);
    }
}

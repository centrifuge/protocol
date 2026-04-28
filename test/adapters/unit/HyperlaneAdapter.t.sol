// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {HyperlaneAdapter} from "../../../src/adapters/HyperlaneAdapter.sol";
import {
    IHyperlaneAdapter,
    IAdapter,
    IMailbox,
    IPostDispatchHook,
    IInterchainSecurityModule,
    HyperlaneSource,
    HyperlaneDestination
} from "../../../src/adapters/interfaces/IHyperlaneAdapter.sol";

contract MockMailbox is Mock {
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata body,
        bytes calldata metadata,
        IPostDispatchHook /* hook */
    ) external payable returns (bytes32) {
        values_uint32["destinationDomain"] = destinationDomain;
        values_bytes32["recipientAddress"] = recipientAddress;
        values_bytes["body"] = body;
        values_bytes["metadata"] = metadata;
        return bytes32("messageId");
    }

    function quoteDispatch(
        uint32, /* destinationDomain */
        bytes32, /* recipientAddress */
        bytes calldata, /* body */
        bytes calldata, /* metadata */
        IPostDispatchHook /* hook */
    ) external pure returns (uint256) {
        return 200_000;
    }
}

contract HyperlaneAdapterTestBase is Test {
    MockMailbox mockMailbox;
    HyperlaneAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint32 constant HYPERLANE_DOMAIN = 2;
    address immutable REMOTE_ADAPTER = makeAddr("remoteAdapter");

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        mockMailbox = new MockMailbox();
        adapter = new HyperlaneAdapter(GATEWAY, address(mockMailbox), address(this));
    }
}

contract HyperlaneAdapterTestWire is HyperlaneAdapterTestBase {
    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));
    }

    function testWire() public {
        vm.expectEmit();
        emit IHyperlaneAdapter.Wire(CENTRIFUGE_ID, HYPERLANE_DOMAIN, REMOTE_ADAPTER);
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));

        (uint32 hyperlaneDomain, address remoteDestAddress) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(hyperlaneDomain, HYPERLANE_DOMAIN);
        assertEq(remoteDestAddress, REMOTE_ADAPTER);

        (uint16 centrifugeId, address remoteSourceAddress) = adapter.sources(HYPERLANE_DOMAIN);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(remoteSourceAddress, REMOTE_ADAPTER);
    }

    function testIsWired() public {
        assertFalse(adapter.isWired(CENTRIFUGE_ID));
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));
        assertTrue(adapter.isWired(CENTRIFUGE_ID));
    }
}

contract HyperlaneAdapterTestSetIsm is HyperlaneAdapterTestBase {
    IInterchainSecurityModule immutable newIsm = IInterchainSecurityModule(makeAddr("newIsm"));

    function testSetIsmErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.setIsm(newIsm);
    }

    function testSetIsm() public {
        assertEq(address(adapter.interchainSecurityModule()), address(0));

        vm.expectEmit();
        emit IHyperlaneAdapter.SetIsm(address(newIsm));
        adapter.setIsm(newIsm);

        assertEq(address(adapter.interchainSecurityModule()), address(newIsm));
    }
}

contract HyperlaneAdapterTest is HyperlaneAdapterTestBase {
    using CastLib for *;

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.mailbox()), address(mockMailbox));
        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimate(uint64 gasLimit) public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));

        bytes memory payload = "irrelevant";
        assertEq(adapter.estimate(CENTRIFUGE_ID, payload, gasLimit), 200_000);
    }

    function testIncomingCalls(
        bytes memory payload,
        address validAddress,
        address invalidAddress,
        uint32 invalidDomain,
        address invalidOrigin
    ) public {
        vm.assume(keccak256(abi.encodePacked(invalidAddress)) != keccak256(abi.encodePacked(validAddress)));
        vm.assume(invalidDomain != HYPERLANE_DOMAIN);
        vm.assume(invalidOrigin != address(mockMailbox));
        assumeNotZeroAddress(validAddress);
        assumeNotZeroAddress(invalidAddress);

        vm.mockCall(
            address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload), abi.encode()
        );

        // Correct input, but not yet setup
        vm.prank(address(mockMailbox));
        vm.expectRevert(IHyperlaneAdapter.InvalidSource.selector);
        adapter.handle(HYPERLANE_DOMAIN, validAddress.toBytes32LeftPadded(), payload);

        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, validAddress));

        // Incorrect address
        vm.prank(address(mockMailbox));
        vm.expectRevert(IHyperlaneAdapter.InvalidSource.selector);
        adapter.handle(HYPERLANE_DOMAIN, invalidAddress.toBytes32LeftPadded(), payload);

        // address(0) from invalid domain should fail
        vm.prank(address(mockMailbox));
        vm.expectRevert(IHyperlaneAdapter.InvalidSource.selector);
        adapter.handle(invalidDomain, address(0).toBytes32LeftPadded(), payload);

        // Incorrect sender (not the mailbox)
        vm.prank(invalidOrigin);
        vm.expectRevert(IHyperlaneAdapter.NotMailbox.selector);
        adapter.handle(HYPERLANE_DOMAIN, validAddress.toBytes32LeftPadded(), payload);

        // Correct
        vm.prank(address(mockMailbox));
        adapter.handle(HYPERLANE_DOMAIN, validAddress.toBytes32LeftPadded(), payload);
    }

    function testOutgoingCalls(bytes calldata payload, address invalidOrigin, uint128 gasLimit, address refund) public {
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.deal(address(this), 0.1 ether);
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        address destinationAdapter = makeAddr("DestinationAdapter");
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, destinationAdapter));

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        assertEq(mockMailbox.values_uint32("destinationDomain"), HYPERLANE_DOMAIN);
        assertEq(mockMailbox.values_bytes32("recipientAddress"), destinationAdapter.toBytes32LeftPadded());
        assertEq(mockMailbox.values_bytes("body"), payload);

        bytes memory expectedMetadata =
            abi.encodePacked(uint16(1), uint256(0), uint256(uint128(gasLimit) + adapter.RECEIVE_COST()), refund);
        assertEq(mockMailbox.values_bytes("metadata"), expectedMetadata);
    }
}

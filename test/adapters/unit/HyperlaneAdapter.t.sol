// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";
import {IAdapterEntrypoint} from "../../../src/core/messaging/interfaces/IAdapterEntrypoint.sol";

import {GasService} from "../../../src/admin/GasService.sol";

import "forge-std/Test.sol";

import {HyperlaneAdapter} from "../../../src/adapters/HyperlaneAdapter.sol";
import {
    IHyperlaneAdapter,
    IAdapter,
    IPostDispatchHook,
    IInterchainSecurityModule
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
        values_uint256["value"] = msg.value;
        return bytes32("messageId");
    }

    /// @dev estimate() is a view function, so this is reached via STATICCALL and cannot write
    ///      state. Echo the metadata hash through the return value so the test can assert the
    ///      exact bytes the adapter built (and that the quote is forwarded unchanged).
    function quoteDispatch(
        uint32, /* destinationDomain */
        bytes32, /* recipientAddress */
        bytes calldata, /* body */
        bytes calldata metadata,
        IPostDispatchHook /* hook */
    )
        external
        pure
        returns (uint256)
    {
        return uint256(keccak256(metadata));
    }
}

contract HyperlaneAdapterTestBase is Test {
    MockMailbox mockMailbox;
    HyperlaneAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint32 constant HYPERLANE_DOMAIN = 2;
    address immutable REMOTE_ADAPTER = makeAddr("remoteAdapter");

    IAdapterEntrypoint constant GATEWAY = IAdapterEntrypoint(address(1));

    GasService gasService;

    /// @dev Mirrors what the adapter declares, so a count that drifts from the adapter's own fails here.
    function receiveCost(uint16 centrifugeId) internal view returns (uint256) {
        return gasService.receiveCost(centrifugeId, "hyperlane");
    }

    function setUp() public {
        uint8[32] memory txLimits;
        gasService = new GasService(txLimits, CENTRIFUGE_ID);
        vm.mockCall(
            address(GATEWAY), abi.encodeWithSelector(IAdapterEntrypoint.messageGas.selector), abi.encode(gasService)
        );

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
        assertEq(adapter.isWired(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER)), false);

        vm.expectEmit();
        emit IHyperlaneAdapter.Wire(CENTRIFUGE_ID, HYPERLANE_DOMAIN, REMOTE_ADAPTER);
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));

        (uint32 hyperlaneDomain, address remoteDestAddress) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(hyperlaneDomain, HYPERLANE_DOMAIN);
        assertEq(remoteDestAddress, REMOTE_ADAPTER);

        (uint16 centrifugeId, address remoteSourceAddress) = adapter.sources(HYPERLANE_DOMAIN);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(remoteSourceAddress, REMOTE_ADAPTER);

        // Wired on both sides: the chain has a destination, and the bridge id has a source
        assertEq(adapter.isWired(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER)), true);
        assertEq(adapter.isWired(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN + 1, REMOTE_ADAPTER)), true);
        assertEq(adapter.isWired(CENTRIFUGE_ID + 1, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER)), true);
        assertEq(adapter.isWired(CENTRIFUGE_ID + 1, abi.encode(HYPERLANE_DOMAIN + 1, REMOTE_ADAPTER)), false);
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

    /// @dev A zero ISM silently defers to the Mailbox default module and must be rejected.
    function testSetIsmRejectsZero() public {
        vm.expectRevert(IHyperlaneAdapter.IsmZero.selector);
        adapter.setIsm(IInterchainSecurityModule(address(0)));
    }
}

contract HyperlaneAdapterTest is HyperlaneAdapterTestBase {
    using CastLib for *;

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.mailbox()), address(mockMailbox));
        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimateErrUnknownChainId(uint64 gasLimit) public {
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.estimate(CENTRIFUGE_ID, "irrelevant", gasLimit);
    }

    function testEstimate(uint64 gasLimit) public {
        adapter.wire(CENTRIFUGE_ID, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));

        // estimate() builds metadata with refund = address(this) (the adapter itself).
        // MockMailbox.quoteDispatch echoes keccak256(metadata), so this asserts the exact bytes.
        bytes memory expectedMetadata = abi.encodePacked(
            uint16(1), uint256(0), uint256(uint256(gasLimit) + receiveCost(CENTRIFUGE_ID)), address(adapter)
        );
        assertEq(adapter.estimate(CENTRIFUGE_ID, "irrelevant", gasLimit), uint256(keccak256(expectedMetadata)));
    }

    /// @dev Monad's cold-access repricing gets a larger per-destination receive reserve.
    function testEstimateUsesMonadReceiveCost(uint64 gasLimit) public {
        uint16 monadId = gasService.MONAD_CENTRIFUGE_ID();
        adapter.wire(monadId, abi.encode(HYPERLANE_DOMAIN, REMOTE_ADAPTER));

        bytes memory expectedMetadata = abi.encodePacked(
            uint16(1), uint256(0), uint256(uint256(gasLimit) + receiveCost(monadId)), address(adapter)
        );
        assertEq(adapter.estimate(monadId, "irrelevant", gasLimit), uint256(keccak256(expectedMetadata)));
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
            address(GATEWAY),
            abi.encodeWithSelector(IMessageHandler.handle.selector, CENTRIFUGE_ID, payload),
            abi.encode()
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
            abi.encodePacked(uint16(1), uint256(0), uint256(uint128(gasLimit) + receiveCost(CENTRIFUGE_ID)), refund);
        assertEq(mockMailbox.values_bytes("metadata"), expectedMetadata);

        // the full fee is forwarded to the mailbox
        assertEq(mockMailbox.values_uint256("value"), 0.1 ether);
    }
}

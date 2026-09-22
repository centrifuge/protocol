// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";

import {Mock} from "../../core/mocks/Mock.sol";

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {ChainlinkAdapter} from "../../../src/adapters/ChainlinkAdapter.sol";
import {
    IChainlinkAdapter,
    IAdapter,
    IClient,
    GENERIC_EXTRA_ARGS_V2_TAG,
    GENERIC_EXTRA_ARGS_V3_TAG,
    WAIT_FOR_FINALITY_FLAG,
    WAIT_FOR_SAFE_FLAG,
    BLOCK_DEPTH_MASK,
    IAny2EVMMessageReceiver,
    IAny2EVMMessageReceiverV2
} from "../../../src/adapters/interfaces/IChainlinkAdapter.sol";

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

contract ChainlinkAdapterTestBase is Test {
    MockCCIPRouter ccipRouter;
    ChainlinkAdapter adapter;

    uint16 constant CENTRIFUGE_ID = 1;
    uint64 constant CHAINLINK_CHAIN_SELECTOR = 2;
    address immutable REMOTE_CHAINLINK_ADDR = makeAddr("remoteAddress");

    IMessageHandler constant GATEWAY = IMessageHandler(address(1));

    function setUp() public {
        ccipRouter = new MockCCIPRouter();
        adapter = new ChainlinkAdapter(GATEWAY, address(ccipRouter), address(this));
    }
}

contract ChainlinkAdapterTestWire is ChainlinkAdapterTestBase {
    using CastLib for *;

    function testWireErrNotAuthorized() public {
        vm.prank(makeAddr("NotAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapter.wire(
            CENTRIFUGE_ID,
            abi.encode(CHAINLINK_CHAIN_SELECTOR, REMOTE_CHAINLINK_ADDR, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG)
        );
    }

    function testWire() public {
        vm.expectEmit();
        emit IChainlinkAdapter.Wire(
            CENTRIFUGE_ID,
            CHAINLINK_CHAIN_SELECTOR,
            REMOTE_CHAINLINK_ADDR,
            WAIT_FOR_FINALITY_FLAG,
            WAIT_FOR_FINALITY_FLAG
        );
        adapter.wire(
            CENTRIFUGE_ID,
            abi.encode(CHAINLINK_CHAIN_SELECTOR, REMOTE_CHAINLINK_ADDR, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG)
        );

        (uint16 centrifugeId, address addr, bytes4 allowedFinality) = adapter.sources(CHAINLINK_CHAIN_SELECTOR);
        assertEq(centrifugeId, CENTRIFUGE_ID);
        assertEq(addr, REMOTE_CHAINLINK_ADDR);
        assertEq(allowedFinality, WAIT_FOR_FINALITY_FLAG);

        (uint64 chainSelector, address addr2, bytes4 requestedFinality) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(chainSelector, CHAINLINK_CHAIN_SELECTOR);
        assertEq(addr2, REMOTE_CHAINLINK_ADDR);
        assertEq(requestedFinality, WAIT_FOR_FINALITY_FLAG);
    }
}

contract ChainlinkAdapterTestFinality is ChainlinkAdapterTestBase {
    function _wire(bytes4 requested, bytes4 allowed) internal {
        adapter.wire(CENTRIFUGE_ID, abi.encode(CHAINLINK_CHAIN_SELECTOR, REMOTE_CHAINLINK_ADDR, requested, allowed));
    }

    function _flags(uint16 bits) internal pure returns (bytes4) {
        return bytes4(uint32(bits) << 16);
    }

    function _depth(uint16 depth) internal pure returns (bytes4) {
        return bytes4(uint32(depth));
    }

    /// @dev Fuzzed over the flag half alone, which is what the mask leaves reachable: a flag CCIP has not defined
    ///      yet wires today and needs no redeploy.
    function testWireStoresFinality(uint16 requestedFlags, uint16 allowedFlags) public {
        bytes4 requested = _flags(requestedFlags);
        bytes4 allowed = _flags(allowedFlags);

        vm.expectEmit();
        emit IChainlinkAdapter.Wire(CENTRIFUGE_ID, CHAINLINK_CHAIN_SELECTOR, REMOTE_CHAINLINK_ADDR, requested, allowed);
        _wire(requested, allowed);

        (,, bytes4 requestedFinality) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(requestedFinality, requested);

        (,, bytes4 allowedFinality) = adapter.sources(CHAINLINK_CHAIN_SELECTOR);
        assertEq(allowedFinality, allowed);
    }

    /// @dev A depth is an assumption about how deep a reorg runs with nothing enforcing it, so neither direction
    ///      may carry one. Refused at wiring time rather than at the FeeQuoter, where it would only surface once
    ///      the lane had already been declared wired.
    function testWireRejectsBlockDepth(uint16 depth) public {
        bytes4 blockDepth = _depth(uint16(bound(depth, 1, type(uint16).max)));

        vm.expectRevert(IChainlinkAdapter.BlockDepthNotSupported.selector);
        _wire(blockDepth, WAIT_FOR_FINALITY_FLAG);

        vm.expectRevert(IChainlinkAdapter.BlockDepthNotSupported.selector);
        _wire(WAIT_FOR_FINALITY_FLAG, blockDepth);
    }

    /// @dev `FinalityCodec._validateRequestedFinality` rejects a flag combined with a depth, and does so inside
    ///      `getFee`, so without this the lane would wire cleanly and then refuse every send.
    function testWireRejectsFlagCombinedWithBlockDepth(uint16 depth) public {
        bytes4 mixed = WAIT_FOR_SAFE_FLAG | _depth(uint16(bound(depth, 1, type(uint16).max)));

        vm.expectRevert(IChainlinkAdapter.BlockDepthNotSupported.selector);
        _wire(mixed, WAIT_FOR_FINALITY_FLAG);

        vm.expectRevert(IChainlinkAdapter.BlockDepthNotSupported.selector);
        _wire(WAIT_FOR_FINALITY_FLAG, mixed);
    }

    /// @dev The mask is the whole guard, so it has to name the same 16 bits CCIP does.
    function testBlockDepthMaskMatchesFinalityCodec() public pure {
        assertEq(BLOCK_DEPTH_MASK, 0xFFFF);
        assertEq(uint32(WAIT_FOR_SAFE_FLAG) & BLOCK_DEPTH_MASK, 0);
        assertEq(uint32(WAIT_FOR_FINALITY_FLAG) & BLOCK_DEPTH_MASK, 0);
    }

    /// @dev The two directions are independent: asking for the `safe` head outbound says nothing about what this
    ///      adapter accepts inbound.
    function testWireFinalityDirectionsAreIndependent() public {
        _wire(WAIT_FOR_SAFE_FLAG, WAIT_FOR_FINALITY_FLAG);

        (,, bytes4 requestedFinality) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(requestedFinality, WAIT_FOR_SAFE_FLAG);

        (,, bytes4 allowedFinality) = adapter.sources(CHAINLINK_CHAIN_SELECTOR);
        assertEq(allowedFinality, WAIT_FOR_FINALITY_FLAG);
    }

    /// @dev Rewiring restates the whole lane, so a lane put back to full finality really is back to full finality.
    function testRewireResetsFinality() public {
        _wire(WAIT_FOR_SAFE_FLAG, WAIT_FOR_SAFE_FLAG);
        _wire(WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG);

        (,, bytes4 requestedFinality) = adapter.destinations(CENTRIFUGE_ID);
        assertEq(requestedFinality, WAIT_FOR_FINALITY_FLAG);

        (,, bytes4 allowedFinality) = adapter.sources(CHAINLINK_CHAIN_SELECTOR);
        assertEq(allowedFinality, WAIT_FOR_FINALITY_FLAG);
    }

    /// @dev A lane left at full finality keeps sending the V2 extra args, which every deployed lane understands.
    function testSendUsesV2ArgsByDefault(bytes calldata payload, uint64 gasLimit) public {
        _wire(WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, address(0));

        assertEq(
            ccipRouter.values_bytes("extraArgs"),
            abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2_TAG,
                IClient.GenericExtraArgsV2({
                    gasLimit: uint256(gasLimit) + adapter.DEFAULT_RECEIVE_COST(), allowOutOfOrderExecution: true
                })
            )
        );
    }

    /// @dev The Fast Confirmation Rule is the `safe` flag in a packed GenericExtraArgsV3: tag, uint32 gas limit,
    ///      finality config, then seven zero length prefixes. Byte-for-byte against
    ///      ExtraArgsCodec._getBasicEncodedExtraArgsV3FastConfirmationRule.
    function testSendUsesV3ArgsWhenFinalityRequested(bytes calldata payload, uint32 gasLimit) public {
        gasLimit = uint32(bound(gasLimit, 0, type(uint32).max - adapter.MONAD_RECEIVE_COST()));
        _wire(WAIT_FOR_SAFE_FLAG, WAIT_FOR_FINALITY_FLAG);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, address(0));

        bytes memory extraArgs = ccipRouter.values_bytes("extraArgs");
        assertEq(
            extraArgs,
            abi.encodePacked(
                GENERIC_EXTRA_ARGS_V3_TAG,
                uint32(gasLimit + adapter.DEFAULT_RECEIVE_COST()),
                WAIT_FOR_SAFE_FLAG,
                bytes7(0)
            )
        );
        assertEq(extraArgs.length, 19);
        assertEq(WAIT_FOR_SAFE_FLAG, bytes4(0x00010000));
    }

    function testSendErrGasLimitTooHigh(bytes calldata payload) public {
        _wire(WAIT_FOR_SAFE_FLAG, WAIT_FOR_FINALITY_FLAG);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IChainlinkAdapter.GasLimitTooHigh.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, type(uint32).max, address(0));
    }

    function testGetCCVsAndFinalityConfig(uint16 allowedFlags) public {
        bytes4 allowed = _flags(allowedFlags);
        _wire(WAIT_FOR_FINALITY_FLAG, allowed);

        (address[] memory required, address[] memory optional, uint8 threshold, bytes4 allowedFinality) =
            adapter.getCCVsAndFinalityConfig(CHAINLINK_CHAIN_SELECTOR, abi.encode(REMOTE_CHAINLINK_ADDR));

        assertEq(required.length, 0);
        assertEq(optional.length, 0);
        assertEq(threshold, 0);
        assertEq(allowedFinality, allowed);
    }

    /// @dev An unwired source is not merely unknown, it must read as "finality only".
    function testGetCCVsAndFinalityConfigUnwired(uint64 chainSelector) public view {
        (,,, bytes4 allowedFinality) = adapter.getCCVsAndFinalityConfig(chainSelector, "");
        assertEq(allowedFinality, WAIT_FOR_FINALITY_FLAG);
    }

    /// @dev Pins the ids themselves, not just that the adapter answers to them: these interfaces are local
    ///      copies of Chainlink's, so a signature edited here moves `type(...).interfaceId`, the adapter keeps
    ///      answering true for the moved id, and the OffRamp, which asks for the real one, gets false. The
    ///      literals are what it asks for.
    function testInterfaceIds() public pure {
        assertEq(type(IAny2EVMMessageReceiver).interfaceId, bytes4(0x85572ffb), "ccipReceive(Any2EVMMessage)");
        assertEq(
            type(IAny2EVMMessageReceiverV2).interfaceId, bytes4(0x1bfc84d0), "getCCVsAndFinalityConfig(uint64,bytes)"
        );
        assertEq(type(IERC165).interfaceId, bytes4(0x01ffc9a7), "supportsInterface(bytes4)");
    }

    /// @dev On a CCIP 2.0 lane the OffRamp reaches `getCCVsAndFinalityConfig` only through
    ///      ERC165CheckerReverting, which takes the answer as support only if 0xffffffff is refused and IERC165
    ///      is acknowledged, and a receiver that fails either falls back to finality-only delivery in silence.
    ///      Catching that needs the real checker; this holds still the values it would read.
    function testSupportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(adapter.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xffffffff));
    }
}

contract ChainlinkAdapterTest is ChainlinkAdapterTestBase {
    using CastLib for *;

    function testDeploy() public view {
        assertEq(address(adapter.entrypoint()), address(GATEWAY));
        assertEq(address(adapter.ccipRouter()), address(ccipRouter));

        assertEq(adapter.wards(address(this)), 1);
    }

    function testEstimateChainlink(uint64 gasLimit) public {
        adapter.wire(
            CENTRIFUGE_ID,
            abi.encode(CHAINLINK_CHAIN_SELECTOR, REMOTE_CHAINLINK_ADDR, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG)
        );

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
        vm.assume(invalidChainSelector != CHAINLINK_CHAIN_SELECTOR);
        vm.assume(invalidOrigin != address(ccipRouter));
        assumeNotZeroAddress(validAddress);
        assumeNotZeroAddress(invalidAddress);

        vm.mockCall(
            address(GATEWAY), abi.encodeWithSelector(GATEWAY.handle.selector, CENTRIFUGE_ID, payload), abi.encode()
        );

        IClient.Any2EVMMessage memory message = IClient.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: CHAINLINK_CHAIN_SELECTOR,
            sender: abi.encode(validAddress),
            data: payload,
            destTokenAmounts: new IClient.EVMTokenAmount[](0)
        });

        // Correct input, but not yet setup
        vm.prank(address(ccipRouter));
        vm.expectRevert(IChainlinkAdapter.InvalidSourceChain.selector);
        adapter.ccipReceive(message);

        adapter.wire(
            CENTRIFUGE_ID,
            abi.encode(CHAINLINK_CHAIN_SELECTOR, validAddress, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG)
        );

        // Incorrect address
        message.sender = abi.encode(invalidAddress);
        vm.prank(address(ccipRouter));
        vm.expectRevert(IChainlinkAdapter.InvalidSourceAddress.selector);
        adapter.ccipReceive(message);

        // Correct sender, but from invalid chain
        message.sender = abi.encode(validAddress);
        message.sourceChainSelector = invalidChainSelector;
        vm.prank(address(ccipRouter));
        vm.expectRevert(IChainlinkAdapter.InvalidSourceChain.selector);
        adapter.ccipReceive(message);

        // Correct message, but incorrect caller
        message.sourceChainSelector = CHAINLINK_CHAIN_SELECTOR;
        vm.prank(invalidOrigin);
        vm.expectRevert(IChainlinkAdapter.InvalidRouter.selector);
        adapter.ccipReceive(message);

        // Correct
        vm.prank(address(ccipRouter));
        adapter.ccipReceive(message);
    }

    function testOutgoingCalls(bytes calldata payload, address invalidOrigin, uint256 gasLimit, address refund) public {
        vm.assume(gasLimit < adapter.DEFAULT_RECEIVE_COST());
        vm.assume(invalidOrigin != address(GATEWAY));

        vm.deal(address(this), 0.1 ether);
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        vm.expectRevert(IAdapter.UnknownChainId.selector);
        adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        adapter.wire(
            CENTRIFUGE_ID,
            abi.encode(
                CHAINLINK_CHAIN_SELECTOR, makeAddr("DestinationAdapter"), WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG
            )
        );

        vm.deal(address(this), 0.1 ether);
        vm.prank(address(GATEWAY));
        bytes32 messageId = adapter.send{value: 0.1 ether}(CENTRIFUGE_ID, payload, gasLimit, refund);

        assertEq(messageId, bytes32(uint256(123)));
        assertEq(ccipRouter.values_uint256("value"), 0.1 ether);
        assertEq(ccipRouter.values_uint64("destinationChainSelector"), CHAINLINK_CHAIN_SELECTOR);
        assertEq(ccipRouter.values_bytes("receiver"), abi.encode(makeAddr("DestinationAdapter")));
        assertEq(ccipRouter.values_bytes("data"), payload);
        assertEq(ccipRouter.values_address("feeToken"), address(0)); // Native token

        // Verify extraArgs contain the gas limit
        bytes memory expectedExtraArgs = abi.encodeWithSelector(
            GENERIC_EXTRA_ARGS_V2_TAG,
            IClient.GenericExtraArgsV2({
                gasLimit: gasLimit + adapter.DEFAULT_RECEIVE_COST(), allowOutOfOrderExecution: true
            })
        );
        assertEq(ccipRouter.values_bytes("extraArgs"), expectedExtraArgs);
    }

    /// @dev Monad's cold-access repricing gets a larger per-destination receive reserve.
    function testSendUsesMonadReceiveCost(bytes calldata payload, uint256 gasLimit, address refund) public {
        gasLimit = bound(gasLimit, 0, type(uint64).max);
        uint16 monadId = adapter.MONAD_CENTRIFUGE_ID();
        adapter.wire(
            monadId,
            abi.encode(
                CHAINLINK_CHAIN_SELECTOR, makeAddr("DestinationAdapter"), WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG
            )
        );

        vm.deal(address(GATEWAY), 0.1 ether);
        vm.prank(address(GATEWAY));
        adapter.send{value: 0.1 ether}(monadId, payload, gasLimit, refund);

        bytes memory expectedExtraArgs = abi.encodeWithSelector(
            GENERIC_EXTRA_ARGS_V2_TAG,
            IClient.GenericExtraArgsV2({
                gasLimit: gasLimit + adapter.MONAD_RECEIVE_COST(), allowOutOfOrderExecution: true
            })
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

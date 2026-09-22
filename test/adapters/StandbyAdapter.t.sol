// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockGateway, MockMessageParser, POOL_0} from "../core/unit/MultiAdapter.t.sol";

import {MultiAdapter} from "../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IMessageGas} from "../../src/core/messaging/interfaces/IMessageGas.sol";
import {IMessageHandler} from "../../src/core/messaging/interfaces/IMessageHandler.sol";
import {IAdapterEntrypoint} from "../../src/core/messaging/interfaces/IAdapterEntrypoint.sol";

import {GasService} from "../../src/admin/GasService.sol";
import {IAdapterGasService} from "../../src/admin/interfaces/IAdapterGasService.sol";

import "forge-std/Test.sol";

import {StandbyAdapter} from "../../src/adapters/StandbyAdapter.sol";
import {IStandbyAdapter} from "../../src/adapters/interfaces/IStandbyAdapter.sol";

/// @dev Records the last send so the test can assert the underlying was (or wasn't) invoked.
contract MockUnderlying is IAdapter {
    uint16 public lastCentrifugeId;
    bytes public lastPayload;
    uint256 public lastValue;
    uint256 public lastGasLimit;
    uint256 public sendCount;
    uint256 public cost;
    uint256 public costPerGas;
    bytes32 public adapterData;

    function setCost(uint256 c) external {
        cost = c;
    }

    function setCostPerGas(uint256 c) external {
        costPerGas = c;
    }

    function setAdapterData(bytes32 d) external {
        adapterData = d;
    }

    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address)
        external
        payable
        returns (bytes32)
    {
        lastCentrifugeId = centrifugeId;
        lastPayload = payload;
        lastValue = msg.value;
        lastGasLimit = gasLimit;
        sendCount++;
        return adapterData;
    }

    /// @dev `costPerGas` is 0 unless a test sets it, so the quote reflects the gasLimit it was asked
    ///      about. `estimate` must stay `view`, so this is how a test observes that argument.
    function estimate(uint16, bytes calldata, uint256 gasLimit) external view returns (uint256) {
        return cost + gasLimit * costPerGas;
    }
}

/// @dev Captures relayed inbound messages (stands in for the MultiAdapter entrypoint).
contract MockEntrypoint is IAdapterEntrypoint {
    IMessageGas public messageGas;
    uint16 public lastCentrifugeId;
    bytes public lastMessage;
    uint256 public handleCount;
    uint256 public voteCount;
    uint256 public executeCount;

    function setGasService(IMessageGas gasService_) external {
        messageGas = gasService_;
    }

    function handle(uint16 centrifugeId, bytes calldata message) external {
        lastCentrifugeId = centrifugeId;
        lastMessage = message;
        handleCount++;
    }

    function vote(uint16 centrifugeId, bytes calldata payload) external {
        lastCentrifugeId = centrifugeId;
        lastMessage = payload;
        voteCount++;
    }

    function execute(uint16 centrifugeId, bytes calldata payload) external {
        lastCentrifugeId = centrifugeId;
        lastMessage = payload;
        executeCount++;
    }
}

contract StandbyAdapterTest is Test {
    uint16 constant REMOTE = 2;
    bytes constant PAYLOAD = hex"c0ffee";
    uint256 constant GAS = 100_000;

    MockEntrypoint entrypoint = new MockEntrypoint();
    MockUnderlying underlying = new MockUnderlying();

    StandbyAdapter standby;
    GasService gasService;

    function setUp() public {
        standby = new StandbyAdapter(IAdapterEntrypoint(address(entrypoint)), underlying);

        uint8[32] memory txLimits;
        gasService = new GasService(txLimits, REMOTE);
        entrypoint.setGasService(gasService);
    }

    /// @dev Mirrors what the adapter declares, so a count that drifts from the adapter's own fails here.
    function receiveCost(uint16 centrifugeId) internal view returns (uint256) {
        return gasService.receiveCost(centrifugeId, "standby");
    }

    /// @dev The underlying holds the standby as its IAdapterEntrypoint and cannot tell the difference, so
    ///      everything an entrypoint is asked for has to be answered. Without these the underlying reverts:
    ///      on messageGas it cannot price its own receive path, and on vote/execute a proof adapter cannot
    ///      sit under a standby at all.
    function testMessageGasPassesThroughToTheEntrypoint() public view {
        assertEq(address(standby.messageGas()), address(gasService));
        assertEq(address(standby.messageGas()), address(entrypoint.messageGas()));
    }

    function testVotePassesThroughToTheEntrypoint() public {
        vm.prank(address(underlying));
        standby.vote(REMOTE, PAYLOAD);

        assertEq(entrypoint.voteCount(), 1);
        assertEq(entrypoint.lastCentrifugeId(), REMOTE);
        assertEq(entrypoint.lastMessage(), PAYLOAD);
    }

    function testExecutePassesThroughToTheEntrypoint() public {
        vm.prank(address(underlying));
        standby.execute(REMOTE, PAYLOAD);

        assertEq(entrypoint.executeCount(), 1);
        assertEq(entrypoint.lastCentrifugeId(), REMOTE);
        assertEq(entrypoint.lastMessage(), PAYLOAD);
    }

    /// @dev Relayed calls are attributed to the standby, so only its own underlying may make them.
    function testVoteErrNotUnderlying(address notUnderlying) public {
        vm.assume(notUnderlying != address(underlying));

        vm.prank(notUnderlying);
        vm.expectRevert(IStandbyAdapter.NotUnderlying.selector);
        standby.vote(REMOTE, PAYLOAD);
    }

    function testExecuteErrNotUnderlying(address notUnderlying) public {
        vm.assume(notUnderlying != address(underlying));

        vm.prank(notUnderlying);
        vm.expectRevert(IStandbyAdapter.NotUnderlying.selector);
        standby.execute(REMOTE, PAYLOAD);
    }

    function _id() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(REMOTE, GAS, PAYLOAD));
    }

    function _send() internal {
        vm.prank(address(entrypoint));
        standby.send(REMOTE, PAYLOAD, GAS, address(this));
    }

    // ─── standby path ─────────────────────────────────────────────────────────────

    function testSendRecordsAndEmitsButDoesNotDispatch() public {
        vm.expectEmit();
        emit IStandbyAdapter.StandbySend(REMOTE, _id(), PAYLOAD, GAS);
        vm.prank(address(entrypoint));
        bytes32 id = standby.send(REMOTE, PAYLOAD, GAS, address(this));

        assertEq(id, _id(), "returns the record id");
        assertEq(underlying.sendCount(), 0, "underlying must not be touched in the happy path");
        assertEq(standby.forwardable(_id()), 1);
    }

    function testRepeatedPayloadsAccumulate() public {
        _send();
        _send();
        // Two sends of the same payload -> two outstanding credits, both forwardable.
        assertEq(standby.forwardable(_id()), 2);
        standby.forward(REMOTE, PAYLOAD, GAS);
        standby.forward(REMOTE, PAYLOAD, GAS);
        assertEq(standby.forwardable(_id()), 0);
        assertEq(underlying.sendCount(), 2);
    }

    function testSendOnlyFromEntrypoint() public {
        vm.expectRevert(IAdapter.NotEntrypoint.selector);
        standby.send(REMOTE, PAYLOAD, GAS, address(this));
    }

    function testDistinctPayloadsTrackedSeparately() public {
        bytes memory other = hex"beef";
        bytes32 idOther = keccak256(abi.encodePacked(REMOTE, GAS, other));

        _send();
        vm.prank(address(entrypoint));
        standby.send(REMOTE, other, GAS, address(this));

        // Credits are keyed by payload; different payloads cannot share or consume each other's credit.
        assertEq(standby.forwardable(_id()), 1);
        assertEq(standby.forwardable(idOther), 1);

        standby.forward(REMOTE, PAYLOAD, GAS);
        assertEq(standby.forwardable(_id()), 0);
        assertEq(standby.forwardable(idOther), 1);
    }

    /// @dev send then forward must round-trip for any (payload, gasLimit): the credit is recorded under
    ///      the exact tuple and consumed once, never exceeding sends. `gasLimit` is fuzzed over the width
    ///      the Gateway provisions (`messageOverallGasLimit` returns uint128), which is the widest value a
    ///      credit can ever carry; `forward`'s uplift arithmetic cannot overflow below it.
    function testFuzzSendForwardRoundTrip(bytes calldata payload, uint128 gasLimit, uint8 sends) public {
        sends = uint8(bound(sends, 1, 10));
        bytes32 id = keccak256(abi.encodePacked(REMOTE, uint256(gasLimit), payload));

        for (uint256 i; i < sends; i++) {
            vm.prank(address(entrypoint));
            standby.send(REMOTE, payload, gasLimit, address(this));
        }
        assertEq(standby.forwardable(id), sends, "one credit per send");

        for (uint256 i; i < sends; i++) {
            standby.forward(REMOTE, payload, gasLimit);
        }
        assertEq(standby.forwardable(id), 0, "all credits consumed");
        assertEq(underlying.sendCount(), sends, "forwards == sends");

        vm.expectRevert(IStandbyAdapter.NotForwardable.selector);
        standby.forward(REMOTE, payload, gasLimit);
    }

    function testSendRejectsValue() public {
        // The standby path never spends value, so attaching any reverts (would otherwise strand).
        vm.deal(address(entrypoint), 1 ether);
        vm.prank(address(entrypoint));
        vm.expectRevert(IStandbyAdapter.UnexpectedValue.selector);
        standby.send{value: 1 ether}(REMOTE, PAYLOAD, GAS, address(this));
    }

    function testEstimateIsZero() public view {
        assertEq(standby.estimate(REMOTE, PAYLOAD, GAS), 0);
    }

    // ─── forward (activation) ───────────────────────────────────────────────────────

    function testForwardDispatchesThroughUnderlying() public {
        _send();

        vm.expectEmit();
        emit IStandbyAdapter.Forward(REMOTE, _id(), PAYLOAD, GAS, bytes32(0));
        standby.forward{value: 1 ether}(REMOTE, PAYLOAD, GAS);

        assertEq(underlying.sendCount(), 1);
        assertEq(underlying.lastCentrifugeId(), REMOTE);
        assertEq(underlying.lastPayload(), PAYLOAD);
        assertEq(underlying.lastValue(), 1 ether, "caller pays the underlying cost");
        assertEq(standby.forwardable(_id()), 0, "credit consumed");
    }

    /// @dev the Forward event must carry the adapterData returned by the underlying adapter.
    function testForwardEmitsUnderlyingAdapterData() public {
        _send();
        bytes32 expected = keccak256("delivery-guid");
        underlying.setAdapterData(expected);

        vm.expectEmit();
        emit IStandbyAdapter.Forward(REMOTE, _id(), PAYLOAD, GAS, expected);
        standby.forward{value: 1 ether}(REMOTE, PAYLOAD, GAS);
    }

    function testForwardRevertsIfNeverSent() public {
        vm.expectRevert(IStandbyAdapter.NotForwardable.selector);
        standby.forward(REMOTE, PAYLOAD, GAS);
    }

    function testForwardRevertsOnWrongGasLimit() public {
        _send(); // recorded with gasLimit GAS
        // gasLimit is bound into the id, so forwarding with a different gas finds no record.
        vm.expectRevert(IStandbyAdapter.NotForwardable.selector);
        standby.forward(REMOTE, PAYLOAD, GAS + 1);
    }

    function testForwardRevertsIfUnderpaid() public {
        _send();
        underlying.setCost(1 ether);
        vm.expectRevert(IStandbyAdapter.NotEnoughValue.selector);
        standby.forward{value: 0.5 ether}(REMOTE, PAYLOAD, GAS);
    }

    /// @dev A forwarded delivery runs one frame deeper than a normal one (underlying -> standby ->
    ///      MultiAdapter), which the sender's gasLimit was not provisioned for: the standby reserves its
    ///      own receive cost and one more EIP-150 64/63 on top of what `send` recorded.
    function testForwardUpliftsGasLimit() public {
        _send();
        standby.forward{value: 1 ether}(REMOTE, PAYLOAD, GAS);

        uint256 expected = (GAS + receiveCost(REMOTE)) * 64 / 63;
        assertGt(expected, GAS, "the underlying must be asked for more than was recorded");
        assertEq(underlying.lastGasLimit(), expected, "send gets the uplifted limit");
    }

    /// @dev The forwarder is quoted for, and pays for, the uplifted limit rather than the recorded one.
    function testForwardEstimatesUpliftedGasLimit() public {
        _send();
        underlying.setCostPerGas(1 wei);
        uint256 expected = (GAS + receiveCost(REMOTE)) * 64 / 63;
        assertEq(standby.estimateForward(REMOTE, PAYLOAD, GAS), expected, "quote exposes the uplifted price");

        vm.expectRevert(IStandbyAdapter.NotEnoughValue.selector);
        standby.forward{value: expected - 1}(REMOTE, PAYLOAD, GAS);

        standby.forward{value: expected}(REMOTE, PAYLOAD, GAS);
        assertEq(underlying.lastValue(), expected);
    }

    /// @dev Monad reprices the cold CALL the relay makes, so it reserves more.
    function testForwardUpliftsGasLimitForMonad() public {
        uint16 monad = gasService.MONAD_CENTRIFUGE_ID();
        vm.prank(address(entrypoint));
        standby.send(monad, PAYLOAD, GAS, address(this));
        standby.forward{value: 1 ether}(monad, PAYLOAD, GAS);

        assertEq(underlying.lastGasLimit(), (GAS + receiveCost(monad)) * 64 / 63);
        assertGt(receiveCost(monad), receiveCost(REMOTE));
    }

    /// @dev The uplift changes only what the underlying is asked for: the credit stays keyed on the
    ///      gasLimit `send` recorded, so an outstanding credit is still forwardable with that same value.
    function testForwardUpliftDoesNotRekeyCredit() public {
        _send();
        standby.forward{value: 1 ether}(REMOTE, PAYLOAD, GAS);
        assertEq(standby.forwardable(_id()), 0, "the recorded gasLimit still finds its credit");
    }

    function testForwardCannotExceedSends() public {
        _send();
        standby.forward(REMOTE, PAYLOAD, GAS);
        vm.expectRevert(IStandbyAdapter.NotForwardable.selector);
        standby.forward(REMOTE, PAYLOAD, GAS);
    }

    // ─── inbound relay ──────────────────────────────────────────────────────────────

    function testHandleRelaysFromUnderlying() public {
        vm.prank(address(underlying));
        standby.handle(REMOTE, PAYLOAD);

        assertEq(entrypoint.handleCount(), 1);
        assertEq(entrypoint.lastCentrifugeId(), REMOTE);
        assertEq(entrypoint.lastMessage(), PAYLOAD);
    }

    function testHandleOnlyFromUnderlying() public {
        vm.expectRevert(IStandbyAdapter.NotUnderlying.selector);
        standby.handle(REMOTE, PAYLOAD);
    }
}

/// @dev Wires a StandbyAdapter as the 3rd slot of a real 2-of-3 MultiAdapter quorum to prove the
///      standby stays idle on send and that a forwarded delivery is attributed as the standby's vote.
contract StandbyAdapterMultiAdapterTest is Test {
    uint16 constant LOCAL = 1;
    uint16 constant REMOTE = 2;
    uint256 constant GAS = 100_000;
    bytes constant PAYLOAD = hex"c0ffee"; // length < 6 -> POOL_0 in MockMessageParser

    MockGateway gateway = new MockGateway();
    MockMessageParser props = new MockMessageParser();
    MultiAdapter multi;

    MockUnderlying activeA = new MockUnderlying();
    MockUnderlying activeB = new MockUnderlying();
    MockUnderlying standbyUnderlying = new MockUnderlying();
    StandbyAdapter standby;

    function setUp() public {
        multi = new MultiAdapter(LOCAL, gateway, address(this));
        multi.file("parser", address(props));

        uint8[32] memory txLimits;
        multi.file("messageGas", address(new GasService(txLimits, LOCAL)));

        standby = new StandbyAdapter(multi, standbyUnderlying);

        IAdapter[] memory set = new IAdapter[](3);
        set[0] = activeA;
        set[1] = activeB;
        set[2] = standby;
        multi.setAdapters(REMOTE, POOL_0, set, 2, 1); // 2-of-3
    }

    /// @dev MultiAdapter wraps outbound payloads with the active sessionId; the standby records that.
    function _wrapped() internal view returns (bytes memory) {
        return abi.encodePacked(multi.activeSessionId(REMOTE, POOL_0), PAYLOAD);
    }

    /// @dev The only place a quote is taken against the real chain of contracts rather than a mocked
    ///      entrypoint: estimateForward reads the reserve through MultiAdapter and the gas service that is
    ///      filed on it, so a reference that is unfiled or does not answer fails here rather than on a live
    ///      message. The other adapters mock `messageGas` away and cannot see this.
    function testEstimateReadsTheFiledGasService() public {
        standbyUnderlying.setCostPerGas(1);

        uint256 receiveCost = IAdapterGasService(address(multi.messageGas())).receiveCost(REMOTE, "standby");
        assertGt(receiveCost, 0, "the standby has a reserve to read");

        assertEq(
            standby.estimateForward(REMOTE, PAYLOAD, GAS),
            (GAS + receiveCost) * 64 / 63,
            "the quote carries the reserve the filed gas service priced"
        );
    }

    function testEstimateRevertsWhenNoGasServiceIsFiled() public {
        multi.file("messageGas", address(0));

        vm.expectRevert();
        standby.estimateForward(REMOTE, PAYLOAD, GAS);
    }

    function testSendKeepsStandbyIdleWhileActivesDispatch() public {
        multi.send(REMOTE, PAYLOAD, GAS, address(this));

        assertEq(activeA.sendCount(), 1, "active A dispatched");
        assertEq(activeB.sendCount(), 1, "active B dispatched");
        assertEq(standbyUnderlying.sendCount(), 0, "standby underlying stays idle");

        bytes32 id = keccak256(abi.encodePacked(REMOTE, GAS, _wrapped()));
        assertEq(standby.forwardable(id), 1, "standby only recorded the send");
    }

    function testForwardedStandbyVoteCountsTowardQuorum() public {
        bytes memory wrapped = _wrapped();

        // activeA delivers: 1 of 2 required votes; gateway must not fire yet.
        vm.prank(address(activeA));
        multi.handle(REMOTE, wrapped);
        assertEq(gateway.count(REMOTE), 0, "one vote is below threshold");

        // The standby's underlying delivers the forwarded message; standby.handle relays it to the
        // MultiAdapter, where msg.sender == standby, so it counts as the standby slot's vote.
        vm.prank(address(standbyUnderlying));
        standby.handle(REMOTE, wrapped);
        assertEq(gateway.count(REMOTE), 1, "standby vote met the 2-of-3 threshold");
    }
}

/// @dev Records the gas the MultiAdapter frame is entered with.
contract GasRecordingEntrypoint is IMessageHandler {
    IAdapterGasService public messageGas;
    uint256 public gasSeen;

    function setGasService(IAdapterGasService gasService_) external {
        messageGas = gasService_;
    }

    function handle(uint16, bytes calldata) external {
        gasSeen = gasleft();
    }
}

/// @dev Stands in for an adapter's inbound frame, which calls its entrypoint with everything it has
///      left, exactly as LayerZeroAdapter.lzReceive and AxelarAdapter.execute do.
contract InboundRelay {
    IMessageHandler public entrypoint;

    function setEntrypoint(IMessageHandler entrypoint_) external {
        entrypoint = entrypoint_;
    }

    function deliver(uint16 centrifugeId, bytes calldata message) external {
        entrypoint.handle(centrifugeId, message);
    }
}

/// @dev The reason `forward` uplifts the gas limit: a forwarded delivery runs one frame deeper than a
///      normal one, so the same limit would enter the MultiAdapter with less gas than the sender
///      provisioned. Measures both paths against each other rather than pinning absolute gas numbers.
contract StandbyAdapterGasTest is Test {
    uint16 constant REMOTE = 2;

    GasRecordingEntrypoint directEntrypoint = new GasRecordingEntrypoint();
    GasRecordingEntrypoint standbyEntrypoint = new GasRecordingEntrypoint();

    InboundRelay direct = new InboundRelay();
    InboundRelay viaStandby = new InboundRelay();
    StandbyAdapter standby;
    GasService gasService;

    function setUp() public {
        // Normal path: adapter -> MultiAdapter
        direct.setEntrypoint(directEntrypoint);

        // Forwarded path: adapter -> standby -> MultiAdapter. The standby only accepts inbound calls
        // from its `underlying`, so the two point at each other.
        standby = new StandbyAdapter(IAdapterEntrypoint(address(standbyEntrypoint)), IAdapter(address(viaStandby)));
        viaStandby.setEntrypoint(standby);

        uint8[32] memory txLimits;
        gasService = new GasService(txLimits, REMOTE);
        standbyEntrypoint.setGasService(gasService);
    }

    function receiveCost(uint16 centrifugeId) internal view returns (uint256) {
        return gasService.receiveCost(centrifugeId, "standby");
    }

    function testForwardUpliftCoversTheRelayFrame(uint32 gasLimit, uint16 messageLength) public {
        gasLimit = uint32(bound(gasLimit, 100_000, 10_000_000));
        bytes memory message = new bytes(bound(messageLength, 0, 8192));

        // What a normal adapter delivers on `gasLimit`, against what the standby delivers on the
        // uplifted limit `forward` hands its underlying.
        uint256 uplifted = (uint256(gasLimit) + receiveCost(REMOTE)) * 64 / 63;

        // The cold CALL into the standby is reserved by the underlying adapter's own receive cost, the
        // same way that adapter reserves the cold CALL into a MultiAdapter entrypoint. Warm it here so
        // this measures only the extra frame the uplift exists for.
        standby.entrypoint();

        direct.deliver{gas: gasLimit}(REMOTE, message);
        viaStandby.deliver{gas: uplifted}(REMOTE, message);

        assertGe(
            standbyEntrypoint.gasSeen(),
            directEntrypoint.gasSeen(),
            "a forwarded delivery must not enter the MultiAdapter with less gas than a normal one"
        );
    }
}

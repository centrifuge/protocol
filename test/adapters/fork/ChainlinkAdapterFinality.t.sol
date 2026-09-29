// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageGas} from "../../../src/core/messaging/interfaces/IMessageGas.sol";
import {IAdapterEntrypoint} from "../../../src/core/messaging/interfaces/IAdapterEntrypoint.sol";

import {GasService} from "../../../src/admin/GasService.sol";

import "forge-std/Test.sol";

import {ChainlinkAdapter} from "../../../src/adapters/ChainlinkAdapter.sol";
import {
    IChainlinkAdapter,
    IClient,
    WAIT_FOR_FINALITY_FLAG,
    WAIT_FOR_SAFE_FLAG
} from "../../../src/adapters/interfaces/IChainlinkAdapter.sol";

/// @dev CCIP's own errors, raised by the FeeQuoter rather than by the adapter, so they are declared here instead of
///      widening the adapter's interface with errors it never emits.
interface ICcipErrors {
    /// @dev A lane still on CCIP 1.5 does not know the V3 extra args tag.
    error InvalidExtraArgsTag();
    /// @dev A lane on CCIP 2.0 knows the tag but does not permit the finality mode asked for.
    error InvalidRequestedFinality(bytes4 requestedFinality, bytes4 allowedFinality);
}

/// @dev Stands in for the MultiAdapter, which the adapter asks for the gas service when it prices its own
///      receive path. A real one is filed, so a quote here goes through the same chain a quote in production does.
contract RecordingHandler is IAdapterEntrypoint {
    IMessageGas public immutable messageGas;

    uint16 public lastCentrifugeId;
    bytes public lastPayload;
    uint256 public handled;

    constructor(IMessageGas messageGas_) {
        messageGas = messageGas_;
    }

    function handle(uint16 centrifugeId, bytes memory payload) external {
        lastCentrifugeId = centrifugeId;
        lastPayload = payload;
        handled++;
    }

    function vote(uint16, bytes calldata) external pure {
        revert("not used");
    }

    function execute(uint16, bytes calldata) external pure {
        revert("not used");
    }
}

/// @title  Chainlink adapter against live CCIP
/// @notice Deploys the adapter on an Ethereum mainnet fork and drives it through the real Router. The unit tests pin
///         what we encode; only this can say whether the live lanes accept it, which is the whole question behind
///         the finality work.
///
///         Three cases, because the lanes are in three different states:
///           1. a lane still on CCIP 1.5, no finality requested       — today's behaviour has to keep working
///           2. a lane on CCIP 2.0, a finality requested              — the 2.0 encoding has to be accepted
///           3. a lane on CCIP 2.0, asking for the Fast Confirmation Rule — not permitted yet, and it reverts
///
/// @dev    Runs only when an archive-capable mainnet RPC is configured, and skips otherwise, so it never fails a CI
///         run that has no network. Set `MAINNET_RPC_URL` (or `ETH_RPC_URL`) and:
///         `forge test --match-path 'test/adapters/fork/ChainlinkAdapterFinality.t.sol' -vv`
contract ChainlinkAdapterFinalityForkTest is Test {
    address constant CCIP_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;

    // Base is on CCIP 2.0, Arc is still on 1.5. Both lanes are live out of Ethereum.
    uint64 constant BASE_CHAIN_SELECTOR = 15971525489660198786;
    uint64 constant ARC_CHAIN_SELECTOR = 6370580034781731079;

    uint16 constant BASE_CENTRIFUGE_ID = 2;
    uint16 constant ARC_CENTRIFUGE_ID = 3;

    // What every 2.0 lane permits today, and what `wire` refuses to carry; kept to assert the lane reports it.
    bytes4 constant ONE_BLOCK_DEPTH = bytes4(uint32(1));
    uint256 constant GAS_LIMIT = 200_000;

    address immutable REMOTE_ADAPTER = makeAddr("remoteChainlinkAdapter");

    RecordingHandler handler;
    ChainlinkAdapter adapter;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", vm.envOr("ETH_RPC_URL", string("")));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        uint8[32] memory txLimits;
        handler = new RecordingHandler(new GasService(txLimits, BASE_CENTRIFUGE_ID));
        adapter = new ChainlinkAdapter(handler, CCIP_ROUTER, address(this));

        _wire(BASE_CENTRIFUGE_ID, BASE_CHAIN_SELECTOR, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG);
        _wire(ARC_CENTRIFUGE_ID, ARC_CHAIN_SELECTOR, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_FINALITY_FLAG);
    }

    function _wire(uint16 centrifugeId, uint64 chainSelector, bytes4 requested, bytes4 allowed) internal {
        adapter.wire(centrifugeId, abi.encode(chainSelector, REMOTE_ADAPTER, requested, allowed));
    }

    /// @dev Quote against the live lane and pay exactly that, so a send here is the send a gateway would make.
    function _send(uint16 centrifugeId, bytes memory payload) internal returns (bytes32) {
        uint256 fee = adapter.estimate(centrifugeId, payload, GAS_LIMIT);
        assertGt(fee, 0, "live lane quoted a fee");

        vm.deal(address(handler), fee);
        vm.prank(address(handler));
        return adapter.send{value: fee}(centrifugeId, payload, GAS_LIMIT, address(0));
    }

    //----------------------------------------------------------------------------------------------
    // Case 1: a lane still on CCIP 1.5
    //----------------------------------------------------------------------------------------------

    /// @dev The default this ships with has to keep working on a lane that knows nothing about 2.0, or the adapter
    ///      cannot be deployed everywhere at once.
    function testLegacyLaneSendsWithDefaultFinality() public {
        assertTrue(_send(ARC_CENTRIFUGE_ID, hex"deadbeef") != bytes32(0), "1.5 lane accepted the message");
    }

    /// @dev The `safe` flag fails there for the same reason, and not the one it fails with on a 2.0 lane. Asserting
    ///      the two errors separately is what keeps "Arc is behind" from being read as "FCR is closed".
    function testLegacyLaneRejectsFastConfirmationRuleAsUnknownTag() public {
        _wire(ARC_CENTRIFUGE_ID, ARC_CHAIN_SELECTOR, WAIT_FOR_SAFE_FLAG, WAIT_FOR_FINALITY_FLAG);

        vm.expectRevert(ICcipErrors.InvalidExtraArgsTag.selector);
        adapter.estimate(ARC_CENTRIFUGE_ID, hex"deadbeef", GAS_LIMIT);
    }

    //----------------------------------------------------------------------------------------------
    // Case 2: a lane on CCIP 2.0
    //----------------------------------------------------------------------------------------------

    function testModernLaneSendsWithDefaultFinality() public {
        assertTrue(_send(BASE_CENTRIFUGE_ID, hex"deadbeef") != bytes32(0), "2.0 lane accepted the v2 args");
    }

    //----------------------------------------------------------------------------------------------
    // Case 3: a lane on CCIP 2.0, asking for the Fast Confirmation Rule
    //----------------------------------------------------------------------------------------------

    /// @dev The `safe` head is encoded correctly and understood — CCIP decodes the request and rejects it against
    ///      the lane's own allowed finality, which is block depth one. So it reverts rather than being ignored,
    ///      which is the answer to whether we can set it early.
    ///
    ///      This is a tripwire, not a wish: when Chainlink admits the flag on this lane the test starts failing, and
    ///      the fix is to delete it and give `testModernLaneSendsWithBlockDepthFinality` the flag instead.
    function testModernLaneRejectsFastConfirmationRule() public {
        _wire(BASE_CENTRIFUGE_ID, BASE_CHAIN_SELECTOR, WAIT_FOR_SAFE_FLAG, WAIT_FOR_FINALITY_FLAG);

        vm.expectRevert(
            abi.encodeWithSelector(ICcipErrors.InvalidRequestedFinality.selector, WAIT_FOR_SAFE_FLAG, ONE_BLOCK_DEPTH)
        );
        adapter.estimate(BASE_CENTRIFUGE_ID, hex"deadbeef", GAS_LIMIT);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @dev Delivery as the live Router performs it: the OffRamp calls the Router, which calls `ccipReceive`. The
    ///      adapter's only trust check is that `msg.sender` is that Router.
    function testReceiveFromLiveRouter() public {
        bytes memory payload = hex"c0ffee";

        vm.prank(CCIP_ROUTER);
        adapter.ccipReceive(_inbound(BASE_CHAIN_SELECTOR, REMOTE_ADAPTER, payload));

        assertEq(handler.handled(), 1);
        assertEq(handler.lastCentrifugeId(), BASE_CENTRIFUGE_ID);
        assertEq(handler.lastPayload(), payload);
    }

    function testReceiveRejectsForeignCaller() public {
        vm.prank(makeAddr("notTheRouter"));
        vm.expectRevert(IChainlinkAdapter.InvalidRouter.selector);
        adapter.ccipReceive(_inbound(BASE_CHAIN_SELECTOR, REMOTE_ADAPTER, hex"c0ffee"));

        assertEq(handler.handled(), 0);
    }

    /// @dev The inbound half of the opt-in, which a 2.0 OffRamp reads before it will deliver a faster-than-finality
    ///      message. Empty verifier lists leave the lane's defaults in place; only the finality policy is ours.
    function testAllowedFinalityIsReportedToCcip() public {
        (address[] memory required, address[] memory optional, uint8 threshold, bytes4 beforeOptIn) =
            adapter.getCCVsAndFinalityConfig(BASE_CHAIN_SELECTOR, abi.encode(REMOTE_ADAPTER));

        assertEq(required.length, 0, "no verifiers of our own");
        assertEq(optional.length, 0);
        assertEq(threshold, 0);
        assertEq(beforeOptIn, WAIT_FOR_FINALITY_FLAG, "wired lanes start finality-only");

        _wire(BASE_CENTRIFUGE_ID, BASE_CHAIN_SELECTOR, WAIT_FOR_FINALITY_FLAG, WAIT_FOR_SAFE_FLAG);

        (,,, bytes4 afterOptIn) = adapter.getCCVsAndFinalityConfig(BASE_CHAIN_SELECTOR, abi.encode(REMOTE_ADAPTER));
        assertEq(afterOptIn, WAIT_FOR_SAFE_FLAG, "opted into `safe` head delivery");
    }

    function _inbound(uint64 chainSelector, address sender, bytes memory payload)
        internal
        pure
        returns (IClient.Any2EVMMessage memory)
    {
        return IClient.Any2EVMMessage({
            messageId: keccak256("messageId"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(sender),
            data: payload,
            destTokenAmounts: new IClient.EVMTokenAmount[](0)
        });
    }
}

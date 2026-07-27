// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {AdapterFailover} from "../../../src/managers/adapters/AdapterFailover.sol";
import {IAdapterFailover} from "../../../src/managers/adapters/interfaces/IAdapterFailover.sol";

import "forge-std/Test.sol";

contract AdapterFailoverTest is Test {
    uint16 constant HUB_CENTRIFUGE_ID = 1;
    PoolId constant POOL_A = PoolId.wrap(1);
    uint64 constant TIMELOCK = 48 hours;

    address multiAdapter = makeAddr("multiAdapter");
    address envoy = makeAddr("envoy");
    address outsider = makeAddr("outsider");
    address steward = makeAddr("steward");

    AdapterFailover adapterFailover;

    IAdapter[] adapters;
    uint8 threshold = 2;

    function setUp() public {
        adapterFailover = new AdapterFailover(envoy, IMultiAdapter(multiAdapter), TIMELOCK);

        // executeFailover derives the next session id from the (mocked) MultiAdapter; keep it at 0 so target == 1.
        vm.mockCall(
            multiAdapter, abi.encodeWithSelector(IMultiAdapter.nextActiveSessionId.selector), abi.encode(uint16(1))
        );

        // Assign the test steward via the hub ManagerCall path.
        vm.prank(envoy);
        adapterFailover.fromHub(POOL_A, abi.encode(uint8(IAdapterFailover.HubCall.UpdateSteward), steward, true));

        adapters.push(IAdapter(makeAddr("adapter1")));
        adapters.push(IAdapter(makeAddr("adapter2")));
        adapters.push(IAdapter(makeAddr("adapter3")));
    }

    function _initiate() internal {
        vm.prank(steward);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function _cancelPayload() internal pure returns (bytes memory) {
        return abi.encode(uint8(IAdapterFailover.HubCall.CancelFailover), HUB_CENTRIFUGE_ID);
    }

    //----------------------------------------------------------------------------------------------
    // initiateFailover
    //----------------------------------------------------------------------------------------------

    function testInitiateFailoverArmsTimelock() public {
        uint64 expectedAt = uint64(block.timestamp) + TIMELOCK;

        vm.expectEmit();
        emit IAdapterFailover.InitiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, expectedAt);
        vm.prank(steward);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);

        (uint64 executableAt, bytes32 paramsHash) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertEq(executableAt, expectedAt);
        assertEq(paramsHash, keccak256(abi.encode(adapters, threshold)));
    }

    /// @dev Documents current behavior: initiateFailover does not require the existing pending proposal
    ///      to be empty/cancelled first, so a steward can overwrite an in-flight proposal (legitimate or
    ///      not) with new parameters, resetting the timelock clock. Pins this down so a future change to
    ///      require cancellation first is a deliberate decision, not an untested behavior change.
    function testInitiateFailoverOverwritesExistingPendingProposal() public {
        _initiate();
        (uint64 firstExecutableAt,) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);

        vm.warp(block.timestamp + 1 hours);

        IAdapter[] memory newAdapters = new IAdapter[](1);
        newAdapters[0] = IAdapter(makeAddr("replacementAdapter"));
        uint8 newThreshold = 1;

        vm.prank(steward);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, newAdapters, newThreshold);

        (uint64 secondExecutableAt, bytes32 paramsHash) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertGt(secondExecutableAt, firstExecutableAt);
        assertEq(paramsHash, keccak256(abi.encode(newAdapters, newThreshold)));
    }

    function testInitiateFailoverOnlySteward() public {
        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function testInitiateFailoverRejectsZeroThreshold() public {
        vm.prank(steward);
        vm.expectRevert(IAdapterFailover.InvalidThreshold.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, 0);
    }

    //----------------------------------------------------------------------------------------------
    // executeFailover
    //----------------------------------------------------------------------------------------------

    function testExecuteFailoverInstallsSetAfterTimelock() public {
        _initiate();
        skip(TIMELOCK);

        vm.expectCall(
            multiAdapter,
            abi.encodeWithSelector(
                IMultiAdapter.setAdapters.selector, HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, uint16(1)
            )
        );
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");

        vm.prank(outsider); // permissionless once armed + elapsed
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);

        (uint64 executableAt,) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertEq(executableAt, 0, "failover cleared");
    }

    function testExecuteFailoverRevertsBeforeTimelock() public {
        _initiate();
        skip(TIMELOCK - 1);

        vm.expectRevert(IAdapterFailover.TimelockNotElapsed.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function testExecuteFailoverRevertsWithoutPending() public {
        vm.expectRevert(IAdapterFailover.NoPendingFailover.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function testExecuteFailoverRevertsOnParamsMismatch() public {
        _initiate();
        skip(TIMELOCK);

        vm.expectRevert(IAdapterFailover.ParamsMismatch.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold + 1);
    }

    function testExecuteFailoverRevertsAfterExpiry() public {
        _initiate();
        // Matured (>= executableAt) but past the one-timelock execution window.
        skip(2 * TIMELOCK + 1);

        vm.expectRevert(IAdapterFailover.FailoverExpired.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function testExecuteFailoverSucceedsAtWindowEnd() public {
        _initiate();
        skip(2 * TIMELOCK); // exactly executableAt + timelock, still valid

        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    //----------------------------------------------------------------------------------------------
    // fromHub (hub operations via ManagerCall/Envoy)
    //----------------------------------------------------------------------------------------------

    function testFromHubVetoesPendingFailover() public {
        _initiate();
        skip(TIMELOCK);

        vm.expectEmit();
        emit IAdapterFailover.BlockFailover(HUB_CENTRIFUGE_ID, POOL_A);
        vm.prank(envoy);
        adapterFailover.fromHub(POOL_A, _cancelPayload());

        // After a veto there is nothing to execute, even though the timelock has elapsed.
        vm.expectRevert(IAdapterFailover.NoPendingFailover.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function testFromHubUpdatesSteward() public {
        assertFalse(adapterFailover.steward(POOL_A, outsider));

        vm.expectEmit();
        emit IAdapterFailover.UpdateSteward(POOL_A, outsider, true);
        vm.prank(envoy);
        adapterFailover.fromHub(POOL_A, abi.encode(uint8(IAdapterFailover.HubCall.UpdateSteward), outsider, true));

        assertTrue(adapterFailover.steward(POOL_A, outsider));

        // The hub-assigned steward can now arm a failover for that pool.
        vm.prank(outsider);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold);
    }

    function testFromHubOnlyEnvoy() public {
        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotEnvoy.selector);
        adapterFailover.fromHub(POOL_A, _cancelPayload());
    }

    function testFromHubRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(IAdapterFailover.UnexpectedValue.selector);
        adapterFailover.fromHub{value: 1}(POOL_A, _cancelPayload());
    }

    //----------------------------------------------------------------------------------------------
    // cancelFailover (steward path)
    //----------------------------------------------------------------------------------------------

    function testCancelFailoverOnlySteward() public {
        _initiate();

        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.cancelFailover(HUB_CENTRIFUGE_ID, POOL_A);

        vm.prank(steward);
        adapterFailover.cancelFailover(HUB_CENTRIFUGE_ID, POOL_A);
        (uint64 executableAt,) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertEq(executableAt, 0);
    }

    function testStewardIsScopedPerPool() public {
        PoolId otherPool = PoolId.wrap(2);
        // steward is only assigned to POOL_A, not otherPool.
        vm.prank(steward);
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, otherPool, adapters, threshold);
    }
}

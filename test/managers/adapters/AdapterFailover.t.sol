// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {AdapterFailover} from "../../../src/managers/adapters/AdapterFailover.sol";
import {IAdapterFailover} from "../../../src/managers/adapters/interfaces/IAdapterFailover.sol";

import "forge-std/Test.sol";

contract AdapterFailoverTest is Test {
    uint16 constant HUB_CENTRIFUGE_ID = 1;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    uint64 constant TIMELOCK = 48 hours;

    address multiAdapter = makeAddr("multiAdapter");
    address contractUpdater = makeAddr("contractUpdater");
    address guardian = address(this);
    address outsider = makeAddr("outsider");

    AdapterFailover adapterFailover;

    IAdapter[] adapters;
    uint8 threshold = 2;
    uint8 recoveryIndex = 0;

    function setUp() public {
        adapterFailover = new AdapterFailover(IMultiAdapter(multiAdapter), contractUpdater, TIMELOCK, guardian);

        // The test contract is the ward (deployer); register it as POOL_A steward so it can drive failover.
        adapterFailover.updateSteward(POOL_A, address(this), true);

        adapters.push(IAdapter(makeAddr("adapter1")));
        adapters.push(IAdapter(makeAddr("adapter2")));
        adapters.push(IAdapter(makeAddr("adapter3")));
    }

    function _initiate() internal {
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    //----------------------------------------------------------------------------------------------
    // initiateFailover
    //----------------------------------------------------------------------------------------------

    function testInitiateFailoverArmsTimelock() public {
        uint64 expectedAt = uint64(block.timestamp) + TIMELOCK;

        vm.expectEmit();
        emit IAdapterFailover.InitiateFailover(
            HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex, expectedAt
        );
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);

        (uint64 executableAt, bytes32 paramsHash) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertEq(executableAt, expectedAt);
        assertEq(paramsHash, keccak256(abi.encode(adapters, threshold, recoveryIndex)));
    }

    function testInitiateFailoverOnlySteward() public {
        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testInitiateFailoverRejectsGlobalPool() public {
        // Steward of the global pool can't exist (updateSteward blocks it), so this reverts on the modifier.
        vm.expectRevert(IAdapterFailover.GlobalPoolNotAllowed.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, PoolId.wrap(0), adapters, threshold, recoveryIndex);
    }

    function testInitiateFailoverRejectsZeroThreshold() public {
        // address(this) is the registered steward.
        vm.expectRevert(IAdapterFailover.InvalidThreshold.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, 0, recoveryIndex);
    }

    function testUpdateStewardRejectsGlobalPool() public {
        vm.expectRevert(IAdapterFailover.GlobalPoolNotAllowed.selector);
        adapterFailover.updateSteward(PoolId.wrap(0), outsider, true);
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
                IMultiAdapter.setAdapters.selector, HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex
            )
        );
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");

        vm.prank(outsider); // permissionless once armed + elapsed
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);

        (uint64 executableAt,) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertEq(executableAt, 0, "failover cleared");
    }

    function testExecuteFailoverRevertsBeforeTimelock() public {
        _initiate();
        skip(TIMELOCK - 1);

        vm.expectRevert(IAdapterFailover.TimelockNotElapsed.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testExecuteFailoverRevertsWithoutPending() public {
        vm.expectRevert(IAdapterFailover.NoPendingFailover.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testExecuteFailoverRevertsOnParamsMismatch() public {
        _initiate();
        skip(TIMELOCK);

        vm.expectRevert(IAdapterFailover.ParamsMismatch.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold + 1, recoveryIndex);
    }

    function testExecuteFailoverRevertsAfterExpiry() public {
        _initiate();
        // Matured (>= executableAt) but past the one-timelock execution window.
        skip(2 * TIMELOCK + 1);

        vm.expectRevert(IAdapterFailover.FailoverExpired.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testExecuteFailoverSucceedsAtWindowEnd() public {
        _initiate();
        skip(2 * TIMELOCK); // exactly executableAt + timelock, still valid

        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.setAdapters.selector), "");
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    //----------------------------------------------------------------------------------------------
    // trustedCall (hub over the pool's adapters)
    //----------------------------------------------------------------------------------------------

    function _cancelPayload() internal pure returns (bytes memory) {
        return abi.encode(uint8(IAdapterFailover.TrustedCall.CancelFailover), HUB_CENTRIFUGE_ID);
    }

    function testTrustedCallVetoesPendingFailover() public {
        _initiate();
        skip(TIMELOCK);

        vm.expectEmit();
        emit IAdapterFailover.BlockFailover(HUB_CENTRIFUGE_ID, POOL_A);
        vm.prank(contractUpdater);
        adapterFailover.trustedCall(POOL_A, SC_1, _cancelPayload());

        // After a veto there is nothing to execute, even though the timelock has elapsed.
        vm.expectRevert(IAdapterFailover.NoPendingFailover.selector);
        adapterFailover.executeFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testTrustedCallUpdatesSteward() public {
        assertFalse(adapterFailover.steward(POOL_A, outsider));

        vm.expectEmit();
        emit IAdapterFailover.UpdateSteward(POOL_A, outsider, true);
        vm.prank(contractUpdater);
        adapterFailover.trustedCall(
            POOL_A, SC_1, abi.encode(uint8(IAdapterFailover.TrustedCall.UpdateSteward), outsider, true)
        );

        assertTrue(adapterFailover.steward(POOL_A, outsider));

        // The hub-assigned steward can now arm a failover for that pool.
        vm.prank(outsider);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testTrustedCallOnlyContractUpdater() public {
        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotContractUpdater.selector);
        adapterFailover.trustedCall(POOL_A, SC_1, _cancelPayload());
    }

    function testTrustedCallUnknownKindReverts() public {
        vm.prank(contractUpdater);
        vm.expectRevert(IAdapterFailover.UnknownTrustedCall.selector);
        adapterFailover.trustedCall(POOL_A, SC_1, abi.encode(uint8(42)));
    }

    function testCancelFailoverOnlySteward() public {
        _initiate();

        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.cancelFailover(HUB_CENTRIFUGE_ID, POOL_A);

        adapterFailover.cancelFailover(HUB_CENTRIFUGE_ID, POOL_A);
        (uint64 executableAt,) = adapterFailover.pendingFailover(HUB_CENTRIFUGE_ID, POOL_A);
        assertEq(executableAt, 0);
    }

    //----------------------------------------------------------------------------------------------
    // blockSession
    //----------------------------------------------------------------------------------------------

    function testBlockSessionForwardsToMultiAdapter() public {
        uint16 sessionId = 3;

        vm.expectCall(
            multiAdapter,
            abi.encodeWithSelector(IMultiAdapter.blockSession.selector, HUB_CENTRIFUGE_ID, POOL_A, sessionId)
        );
        vm.mockCall(multiAdapter, abi.encodeWithSelector(IMultiAdapter.blockSession.selector), "");

        adapterFailover.blockSession(HUB_CENTRIFUGE_ID, POOL_A, sessionId);
    }

    function testBlockSessionOnlySteward() public {
        vm.prank(outsider);
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.blockSession(HUB_CENTRIFUGE_ID, POOL_A, 1);
    }

    //----------------------------------------------------------------------------------------------
    // updateSteward
    //----------------------------------------------------------------------------------------------

    function testUpdateSteward() public {
        assertFalse(adapterFailover.steward(POOL_A, outsider));

        vm.expectEmit();
        emit IAdapterFailover.UpdateSteward(POOL_A, outsider, true);
        adapterFailover.updateSteward(POOL_A, outsider, true);
        assertTrue(adapterFailover.steward(POOL_A, outsider));

        // A newly-granted steward can now arm a failover for that pool.
        vm.prank(outsider);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, POOL_A, adapters, threshold, recoveryIndex);
    }

    function testUpdateStewardOnlyAuth() public {
        vm.prank(outsider);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        adapterFailover.updateSteward(POOL_A, outsider, true);
    }

    function testStewardIsScopedPerPool() public {
        PoolId otherPool = PoolId.wrap(2);
        // address(this) is steward for POOL_A only (from setUp), not for otherPool.
        vm.expectRevert(IAdapterFailover.NotSteward.selector);
        adapterFailover.initiateFailover(HUB_CENTRIFUGE_ID, otherPool, adapters, threshold, recoveryIndex);
    }

    //----------------------------------------------------------------------------------------------
    // file
    //----------------------------------------------------------------------------------------------

    function testFileTimelock() public {
        adapterFailover.file("timelock", 1 days);
        assertEq(adapterFailover.timelock(), 1 days);
    }

    function testFileUnrecognized() public {
        vm.expectRevert(IAdapterFailover.FileUnrecognizedParam.selector);
        adapterFailover.file("unknown", 1);
    }
}

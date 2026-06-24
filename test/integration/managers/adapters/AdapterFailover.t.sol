// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PoolId, newPoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";

import {IAdapterFailover} from "../../../../src/managers/adapters/interfaces/IAdapterFailover.sol";

import {CentrifugeIntegrationTest} from "../../Integration.t.sol";
import {IntegrationConstants} from "../../utils/IntegrationConstants.sol";

/// @notice End-to-end exercise of the deployed AdapterFailover against the deployed MultiAdapter:
///         a steward arms a failover, the hub can veto it over the trusted-contract-update path, and
///         once the timelock elapses (unvetoed) anyone installs the new adapter set locally.
contract AdapterFailoverIntegrationTest is CentrifugeIntegrationTest {
    uint16 constant REMOTE = IntegrationConstants.CENTRIFUGE_ID_B;
    uint8 constant THRESHOLD = 1;
    uint8 constant RECOVERY_INDEX = 0;

    PoolId poolId = newPoolId(LOCAL_CENTRIFUGE_ID, 1);
    address steward = makeAddr("steward");

    IAdapter[] deadAdapters;
    IAdapter[] newAdapters;

    function setUp() public override {
        super.setUp();

        deadAdapters.push(IAdapter(makeAddr("deadAdapter")));
        newAdapters.push(IAdapter(makeAddr("newAdapter1")));
        newAdapters.push(IAdapter(makeAddr("newAdapter2")));

        vm.startPrank(address(root));
        // The pool's current adapter set for the REMOTE channel (the one that will "go dark").
        multiAdapter.setAdapters(REMOTE, poolId, deadAdapters, 1, 0);
        // Enable failover for the pool: AdapterFailover becomes a MultiAdapter manager with a steward.
        multiAdapter.updateManager(poolId, address(adapterFailover), true);
        adapterFailover.updateSteward(poolId, steward, true);
        vm.stopPrank();
    }

    function _cancelPayload() internal pure returns (bytes memory) {
        return abi.encode(uint8(IAdapterFailover.TrustedCall.CancelFailover), REMOTE);
    }

    function testExecuteInstallsNewAdapterSet() public {
        vm.prank(steward);
        adapterFailover.initiateFailover(REMOTE, poolId, newAdapters, THRESHOLD, RECOVERY_INDEX);

        vm.warp(block.timestamp + adapterFailover.timelock());

        // Permissionless once armed and elapsed.
        adapterFailover.executeFailover(REMOTE, poolId, newAdapters, THRESHOLD, RECOVERY_INDEX);

        IMultiAdapter.Adapters memory active = multiAdapter.activeAdapters(REMOTE, poolId);
        assertEq(active.list.length, newAdapters.length, "new set installed");
        assertEq(address(active.list[0]), address(newAdapters[0]));
        assertEq(address(active.list[1]), address(newAdapters[1]));
    }

    function testHubVetoBlocksFailover() public {
        vm.prank(steward);
        adapterFailover.initiateFailover(REMOTE, poolId, newAdapters, THRESHOLD, RECOVERY_INDEX);

        // The hub vetoes while the pool's adapters still function, over the trusted-contract-update path.
        vm.prank(address(contractUpdater));
        adapterFailover.trustedCall(poolId, ShareClassId.wrap(0), _cancelPayload());

        vm.warp(block.timestamp + adapterFailover.timelock());

        vm.expectRevert(IAdapterFailover.NoPendingFailover.selector);
        adapterFailover.executeFailover(REMOTE, poolId, newAdapters, THRESHOLD, RECOVERY_INDEX);

        // The original set is untouched after a veto.
        IMultiAdapter.Adapters memory active = multiAdapter.activeAdapters(REMOTE, poolId);
        assertEq(active.list.length, deadAdapters.length, "original set kept");
        assertEq(address(active.list[0]), address(deadAdapters[0]));
    }

    function testHubAssignsStewardOverContractUpdate() public {
        address newSteward = makeAddr("newSteward");

        vm.prank(address(contractUpdater));
        adapterFailover.trustedCall(
            poolId,
            ShareClassId.wrap(0),
            abi.encode(uint8(IAdapterFailover.TrustedCall.UpdateSteward), newSteward, true)
        );

        // The hub-assigned steward can now drive a failover end to end.
        vm.prank(newSteward);
        adapterFailover.initiateFailover(REMOTE, poolId, newAdapters, THRESHOLD, RECOVERY_INDEX);
        vm.warp(block.timestamp + adapterFailover.timelock());
        adapterFailover.executeFailover(REMOTE, poolId, newAdapters, THRESHOLD, RECOVERY_INDEX);

        assertEq(multiAdapter.activeAdapters(REMOTE, poolId).list.length, newAdapters.length);
    }
}

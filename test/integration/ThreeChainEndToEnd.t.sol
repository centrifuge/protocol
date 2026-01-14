// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {LocalAdapter} from "./adapters/LocalAdapter.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {IShareToken} from "../../src/core/spoke/interfaces/IShareToken.sol";
import {MessageLib} from "../../src/core/messaging/libraries/MessageLib.sol";

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {FullDeployer} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

enum CrossChainDirection {
    WithIntermediaryHub, // (spoke in C) -> (hub in A) -> (spoke in B)
    FromHub, // (spoke in A) -> (hub in A) -> (spoke in B)
    ToHub // (spoke in C) -> (hub in A) -> (spoke in A)
}

/// @title  Three Chain End-to-End Test
/// @notice Extends the dual-chain setup to include a third chain (C) which acts as an additional spoke
///         Hub is always deployed in A.
contract ThreeChainEndToEndDeployment is EndToEndFlows {
    using CastLib for *;
    using MessageLib for *;

    uint16 constant CENTRIFUGE_ID_C = IntegrationConstants.CENTRIFUGE_ID_C;
    ISafe immutable safeAdminC = ISafe(makeAddr("SafeAdminC"));

    uint128 AMOUNT = 1e18;

    FullDeployer deployC = new FullDeployer();
    LocalAdapter adapterCToA;
    LocalAdapter adapterAToC;

    CSpoke origin;
    CSpoke dest;

    function setUp() public override {
        // Call the original setUp to set up chains A and B
        super.setUp();

        // Deploy the third chain (C)
        adapterCToA = _deployChain(deployC, CENTRIFUGE_ID_C, CENTRIFUGE_ID_A, safeAdminC);

        // Connect Chain A to Chain C (spoke 2)
        adapterAToC = new LocalAdapter(CENTRIFUGE_ID_A, deployA.multiAdapter(), address(deployA));
        _setAdapter(deployA, CENTRIFUGE_ID_C, adapterAToC);

        adapterCToA.setEndpoint(adapterAToC);
        adapterAToC.setEndpoint(adapterCToA);

        vm.label(address(adapterAToC), "AdapterAToC");
        vm.label(address(adapterCToA), "AdapterCToA");
    }

    function _setSpokes(CrossChainDirection direction) internal {
        // NOTE: Hub is always in deployA.
        if (direction == CrossChainDirection.WithIntermediaryHub) {
            _setSpoke(deployC, CENTRIFUGE_ID_C, origin);
            _setSpoke(deployB, CENTRIFUGE_ID_B, dest);
        } else if (direction == CrossChainDirection.FromHub) {
            _setSpoke(deployA, CENTRIFUGE_ID_A, origin);
            _setSpoke(deployB, CENTRIFUGE_ID_B, dest);
        } else if (direction == CrossChainDirection.ToHub) {
            _setSpoke(deployC, CENTRIFUGE_ID_C, origin);
            _setSpoke(deployA, CENTRIFUGE_ID_A, dest);
        }
    }

    /// @notice Test transferring shares between Chain B and Chain C via Hub A
    function _testCrossChainTransferShares(CrossChainDirection direction) internal {
        _setSpokes(direction);
        _createPool();
        _configurePoolInSpoke(origin);
        _configurePoolInSpoke(dest);

        vm.startPrank(FM);
        h.hub.updateSharePrice(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, origin.centrifugeId, REFUND);

        // B: Mint shares
        vm.startPrank(BSM);
        IShareToken shareTokenB = IShareToken(origin.spoke.shareToken(POOL_A, SC_1));
        origin.balanceSheet.issue(POOL_A, SC_1, INVESTOR_A, AMOUNT);
        origin.balanceSheet.submitQueuedShares{value: GAS}(POOL_A, SC_1, 0, REFUND);
        vm.stopPrank();
        assertEq(shareTokenB.balanceOf(INVESTOR_A), AMOUNT, "Investor should have minted shares on chain B");

        // B: Initiate transfer of shares
        vm.expectEmit();
        emit ISpoke.InitiateTransferShares(dest.centrifugeId, POOL_A, SC_1, INVESTOR_A, INVESTOR_A.toBytes32(), AMOUNT);
        vm.expectEmit();
        emit IHub.ForwardTransferShares(
            origin.centrifugeId, dest.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), AMOUNT
        );

        // If hub is not source, then message will be pending as unpaid on hub until repaid
        if (direction == CrossChainDirection.WithIntermediaryHub) {
            vm.expectEmit(true, false, false, false);
            emit IGateway.UnderpaidBatch(dest.centrifugeId, bytes(""), bytes32(0));
        } else {
            vm.expectEmit();
            emit ISpoke.ExecuteTransferShares(POOL_A, SC_1, INVESTOR_A, AMOUNT);
        }

        vm.prank(INVESTOR_A);
        origin.spoke.crosschainTransferShares{value: GAS}(
            dest.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), AMOUNT, HOOK_GAS, HOOK_GAS, INVESTOR_A
        );
        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should be burned on chain B");
        assertEq(
            h.snapshotHook.transfers(POOL_A, SC_1, origin.centrifugeId, dest.centrifugeId),
            AMOUNT,
            "Snapshot hook not called"
        );

        // C: Transfer expected to be pending on A due to message being unpaid
        IShareToken shareTokenC = IShareToken(dest.spoke.shareToken(POOL_A, SC_1));

        // If hub is not source, then message will be pending as unpaid on hub until repaid
        if (direction == CrossChainDirection.WithIntermediaryHub) {
            assertEq(shareTokenC.balanceOf(INVESTOR_A), 0, "Share transfer not executed due to unpaid message");

            vm.prank(ANY);
            vm.expectEmit();
            emit ISpoke.ExecuteTransferShares(POOL_A, SC_1, INVESTOR_A, AMOUNT);
            h.gateway.repay{value: GAS}(dest.centrifugeId, _getLastUnpaidMessage(), REFUND);
        }

        // C: Verify shares were minted
        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should still be burned on chain B");
        assertEq(shareTokenC.balanceOf(INVESTOR_A), AMOUNT, "Shares minted on chain C");
    }
}

/// @title  Three Chain End-to-End Use Cases
/// @notice Test cases for the three-chain setup
contract ThreeChainEndToEndUseCases is ThreeChainEndToEndDeployment {
    /// @notice Test transferring shares: C (Spoke1) -> A (Hub) -> B (Spoke2)
    /// forge-config: default.isolate = true
    function testCrossChainTransferShares_WithIntermediaryHubChain() public {
        _testCrossChainTransferShares(CrossChainDirection.WithIntermediaryHub);
    }

    /// @notice Test transferring shares: C (Spoke1, Hub) -> B (Spoke2)
    /// forge-config: default.isolate = true
    function testCrossChainTransferShares_FromHubChain() public {
        _testCrossChainTransferShares(CrossChainDirection.FromHub);
    }

    /// @notice Test transferring shares: C (Spoke1) -> B (Spoke2, Hub)
    /// forge-config: default.isolate = true
    function testCrossChainTransferShares_ToHubChain() public {
        _testCrossChainTransferShares(CrossChainDirection.ToHub);
    }
}

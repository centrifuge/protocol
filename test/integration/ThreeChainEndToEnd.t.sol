// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {LocalAdapter} from "./adapters/LocalAdapter.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {ISafe} from "../../src/common/interfaces/IGuardian.sol";
import {IGateway} from "../../src/common/interfaces/IGateway.sol";
import {MessageLib} from "../../src/common/libraries/MessageLib.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {IMultiAdapter} from "../../src/common/interfaces/IMultiAdapter.sol";

import {IHub} from "../../src/hub/interfaces/IHub.sol";

import {ISpoke} from "../../src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

import {FullDeployer} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

enum CrossChainDirection {
    WithIntermediaryHub, // C -> A -> B (Hub is on A)
    FromHub, // C => A -> B (Hub is on A)
    ToHub // C -> A => B (Hub is on A)

}

/// @title  Three Chain End-to-End Test
/// @notice Extends the dual-chain setup to include a third chain (C) which acts as an additional spoke
///         Hub is on Chain A, with spokes on Chains B and C
///         C is considered the source chain, B the destination chain
///         Depending on the cross chain direction, the hub is either on A or B or C
contract ThreeChainEndToEndDeployment is EndToEndFlows {
    using CastLib for *;
    using MessageLib for *;

    uint16 constant CENTRIFUGE_ID_C = IntegrationConstants.CENTRIFUGE_ID_C;
    ISafe immutable safeAdminC = ISafe(makeAddr("SafeAdminC"));

    FullDeployer deployC = new FullDeployer();
    LocalAdapter adapterCToA;
    LocalAdapter adapterAToC;

    CSpoke sC;
    CSpoke sB;

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
            _setSpoke(deployB, CENTRIFUGE_ID_B, sB);
            _setSpoke(deployC, CENTRIFUGE_ID_C, sC);
        } else if (direction == CrossChainDirection.FromHub) {
            _setSpoke(deployB, CENTRIFUGE_ID_B, sB);
            _setSpoke(deployA, CENTRIFUGE_ID_A, sC);
        } else if (direction == CrossChainDirection.ToHub) {
            _setSpoke(deployA, CENTRIFUGE_ID_A, sB);
            _setSpoke(deployC, CENTRIFUGE_ID_C, sC);
        }
    }

    /// @notice Configure the third chain (C) with assets
    function _testConfigureAssets(CrossChainDirection direction) internal {
        _setSpokes(direction);
        _configureAsset(sB);
        _configureAsset(sC);
    }

    /// @notice Configure a pool with support for all three chains
    function _testConfigurePool(CrossChainDirection direction) internal {
        _setSpokes(direction);
        _configurePool(sB);
        _configurePool(sC);
    }

    /// @notice Test transferring shares between Chain B and Chain C via Hub A
    function _testCrossChainTransferShares(CrossChainDirection direction) internal {
        uint128 amount = 1e18;

        _testConfigurePool(direction);

        vm.startPrank(FM);
        h.hub.updateSharePrice(POOL_A, SC_1, d18(1, 1));
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, sB.centrifugeId);

        // B: Mint shares
        vm.startPrank(BSM);
        IShareToken shareTokenB = IShareToken(sB.spoke.shareToken(POOL_A, SC_1));
        sB.balanceSheet.issue(POOL_A, SC_1, INVESTOR_A, amount);
        sB.balanceSheet.submitQueuedShares(POOL_A, SC_1, 0);
        vm.stopPrank();
        assertEq(shareTokenB.balanceOf(INVESTOR_A), amount, "Investor should have minted shares on chain B");

        // B: Initiate transfer of shares
        vm.expectEmit();
        emit ISpoke.InitiateTransferShares(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A, INVESTOR_A.toBytes32(), amount);
        emit IHub.ForwardTransferShares(sB.centrifugeId, sC.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), amount);

        // If hub is not source, then message will be pending as unpaid on hub until repaid
        if (direction == CrossChainDirection.WithIntermediaryHub) {
            vm.expectEmit(true, false, false, false);
            emit IGateway.UnderpaidBatch(sC.centrifugeId, bytes(""), bytes32(0));
        } else {
            vm.expectEmit();
            emit ISpoke.ExecuteTransferShares(POOL_A, SC_1, INVESTOR_A, amount);
        }

        vm.prank(INVESTOR_A);
        sB.spoke.crosschainTransferShares{value: GAS}(
            sC.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), amount, 0, SHARE_HOOK_GAS
        );
        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should be burned on chain B");

        // C: Transfer expected to be pending on A due to message being unpaid
        IShareToken shareTokenC = IShareToken(sC.spoke.shareToken(POOL_A, SC_1));

        // If hub is not source, then message will be pending as unpaid on hub until repaid
        if (direction == CrossChainDirection.WithIntermediaryHub) {
            assertEq(shareTokenC.balanceOf(INVESTOR_A), 0, "Share transfer not executed due to unpaid message");
            bytes memory message = MessageLib.ExecuteTransferShares({
                poolId: PoolId.unwrap(POOL_A),
                scId: ShareClassId.unwrap(SC_1),
                receiver: INVESTOR_A.toBytes32(),
                amount: amount
            }).serialize();

            // A: Repay for unpaid ExecuteTransferShares message on A to trigger sending it to C if A != C
            vm.expectEmit(true, false, false, false);
            emit IMultiAdapter.HandlePayload(h.centrifugeId, bytes32(""), bytes(""), adapterCToA);
            vm.expectEmit();
            emit ISpoke.ExecuteTransferShares(POOL_A, SC_1, INVESTOR_A, amount);

            vm.startPrank(ANY);
            h.gateway.repay{value: GAS}(sC.centrifugeId, message);
        }

        // C: Verify shares were minted
        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should still be burned on chain B");
        assertEq(shareTokenC.balanceOf(INVESTOR_A), amount, "Shares minted on chain C");
    }
}

/// @title  Three Chain End-to-End Use Cases
/// @notice Test cases for the three-chain setup
contract ThreeChainEndToEndUseCases is ThreeChainEndToEndDeployment {
    /// @notice Test configuring assets: C (Spoke1) -> A (Hub) -> B (Spoke2)
    /// forge-config: default.isolate = true
    function testConfigureAssets_WithIntermediaryHubChain() public {
        _testConfigureAssets(CrossChainDirection.WithIntermediaryHub);
    }

    /// @notice Test configuring assets: C (Spoke1, Hub) -> B (Spoke2)
    /// forge-config: default.isolate = true
    function testConfigureAssets_FromHubChain() public {
        _testConfigureAssets(CrossChainDirection.FromHub);
    }

    /// @notice Test configuring assets: C (Spoke1) -> B (Spoke2, Hub)
    /// forge-config: default.isolate = true
    function testConfigureAssets_ToHubChain() public {
        _testConfigureAssets(CrossChainDirection.ToHub);
    }

    /// @notice Test configuring a pool: C (Spoke1) -> A (Hub) -> B (Spoke2)
    /// forge-config: default.isolate = true
    function testConfigurePool_WithIntermediaryHubChain() public {
        _testConfigurePool(CrossChainDirection.WithIntermediaryHub);
    }

    /// @notice Test configuring a pool: C (Spoke1, Hub) -> B (Spoke2)
    /// forge-config: default.isolate = true
    function testConfigurePool_FromHubChain() public {
        _testConfigurePool(CrossChainDirection.FromHub);
    }

    /// @notice Test configuring a pool: C (Spoke1) -> B (Spoke2, Hub)
    /// forge-config: default.isolate = true
    function testConfigurePool_ToHubChain() public {
        _testConfigurePool(CrossChainDirection.ToHub);
    }

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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMultiAdapter} from "src/common/interfaces/adapters/IMultiAdapter.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";

import "test/integration/EndToEnd.t.sol";

/// @title  Three Chain End-to-End Test
/// @notice Extends the dual-chain setup to include a third chain (C) which acts as an additional spoke
///         Hub is on Chain A, with spokes on Chains B and C
contract ThreeChainEndToEndDeployment is EndToEndUtils {
    using CastLib for *;

    uint16 constant CENTRIFUGE_ID_C = 7;
    ISafe immutable safeAdminC = ISafe(makeAddr("SafeAdminC"));

    FullDeployer deployC = new FullDeployer();
    LocalAdapter adapterCToA;
    LocalAdapter adapterAToC;

    CSpoke sC;
    CSpoke sB;

    function setUp() public override {
        // Call the original setUp to set up chains A and B
        super.setUp();
        _setSpoke(deployB, CENTRIFUGE_ID_B, sB);

        // Deploy the third chain (C)
        adapterCToA = _deployChain(deployC, CENTRIFUGE_ID_C, CENTRIFUGE_ID_A, safeAdminC);
        _setSpoke(deployC, CENTRIFUGE_ID_C, sC);

        // Connect Chain A to Chain C (spoke 2)
        adapterAToC = new LocalAdapter(CENTRIFUGE_ID_A, deployA.multiAdapter(), address(deployA));
        vm.startPrank(address(h.guardian.safe()));
        deployA.wire(CENTRIFUGE_ID_C, adapterAToC, address(adapterAToC));
        vm.stopPrank();

        adapterCToA.setEndpoint(adapterAToC);
        adapterAToC.setEndpoint(adapterCToA);

        vm.label(address(adapterAToC), "AdapterAToC");
        vm.label(address(adapterCToA), "AdapterCToA");
    }
}

/// @title  Three Chain End-to-End Use Cases
/// @notice Test cases for the three-chain setup
contract ThreeChainEndToEndUseCases is ThreeChainEndToEndDeployment {
    using CastLib for *;
    using MessageLib for *;

    /// @notice Configure the third chain (C) with assets
    /// forge-config: default.isolate = true
    function testConfigureAssets() public {
        _configureAsset(sB);
        _configureAsset(sC);
    }

    /// @notice Configure a pool with support for all three chains
    /// forge-config: default.isolate = true
    function testConfigurePool() public {
        _configurePool(sB);
        _configurePool(sC);
    }

    /// @notice Test transferring shares between Chain B and Chain C via Hub A
    /// forge-config: default.isolate = true
    function testCrossChainTransferShares(uint128 amount) public {
        vm.assume(amount != 0);

        testConfigurePool();

        // B: Mint shares
        vm.startPrank(address(sB.root));
        IShareToken shareTokenB = IShareToken(sB.spoke.shareToken(POOL_A, SC_1));
        shareTokenB.mint(INVESTOR_A, amount);
        vm.stopPrank();
        assertEq(shareTokenB.balanceOf(INVESTOR_A), amount, "Investor should have minted shares on chain B");

        // B: Initiate transfer of shares
        vm.expectEmit();
        emit ISpoke.TransferShares(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A, INVESTOR_A.toBytes32(), amount);
        emit IHub.ForwardTransferShares(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), amount);
        vm.expectEmit(true, false, false, false);
        emit IGateway.UnderpaidBatch(sC.centrifugeId, bytes(""));
        vm.prank(INVESTOR_A);
        sB.spoke.transferShares{value: GAS}(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), amount);

        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should be burned on chain B");

        // C: Transfer expected to be pending on A due to message being unpaid
        IShareToken shareTokenC = IShareToken(sC.spoke.shareToken(POOL_A, SC_1));
        assertEq(shareTokenC.balanceOf(INVESTOR_A), 0, "Share transfer not executed due to unpaid message");

        // A: Before calling repay, set a refund address for the pool
        vm.prank(address(h.root));
        h.gateway.setRefundAddress(POOL_A, IRecoverable(h.gateway));

        // A: Repay for unpaid ExecuteTransferShares message on A to trigger sending it to C
        bytes memory message = MessageLib.ExecuteTransferShares({
            poolId: PoolId.unwrap(POOL_A),
            scId: ShareClassId.unwrap(SC_1),
            receiver: INVESTOR_A.toBytes32(),
            amount: amount
        }).serialize();
        vm.expectEmit(true, false, false, false);
        emit IMultiAdapter.HandlePayload(h.centrifugeId, bytes32(""), bytes(""), adapterCToA);
        vm.expectEmit();
        emit ISpoke.ExecuteTransferShares(POOL_A, SC_1, INVESTOR_A, amount);
        h.gateway.repay{value: DEFAULT_SUBSIDY}(sC.centrifugeId, message);

        // C: Verify shares were minted
        assertEq(shareTokenC.balanceOf(INVESTOR_A), amount, "Shares should be minted on chain C");
        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should still be burned on chain B");
    }
}

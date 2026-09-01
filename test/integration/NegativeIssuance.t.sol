// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";

import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";
import {MessageLib, ManagerKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev The same situation as `NAVManagerNegativeIssuanceTest`, but over two real chains and the spoke's own
///      share queue. Shares are bridged off one chain before it submits the issuance that minted them, and
///      the other chain then revokes more than the hub knows about. That revocation has to be accepted: by
///      the time the hub sees the message the spoke has already emptied its queue and moved its nonce on, so
///      a revert would lose the amount entirely and stop the spoke reporting for good.
contract NegativeIssuanceEndToEndTest is EndToEndFlows {
    using CastLib for *;
    using MessageLib for *;

    uint128 constant SHARES = 1000e18;

    IShareToken shareOnHub;
    IShareToken shareOnSpoke;
    Spoke spokeHub;

    function _setUpBothChains() internal {
        _configurePool(false);
        _configurePrices(d18(1, 1), d18(1, 1));

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, h.centrifugeId, REFUND);
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, SC_1, h.centrifugeId, address(deployA.shareTokenRegistrar()).toBytes32(), "", 0, REFUND
        );
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, h.centrifugeId, REFUND);
        h.hub.updateManager{value: GAS}(POOL_A, h.centrifugeId, ManagerKind.Spoke, BSM.toBytes32(), true, REFUND);
        // The pool allowlists the investor as a bridger, as it must for any cross-chain share movement.
        h.hub.updateManager{value: GAS}(
            POOL_A, h.centrifugeId, ManagerKind.Bridger, INVESTOR_A.toBytes32(), true, REFUND
        );
        vm.stopPrank();

        spokeHub = deployA.spoke();
        shareOnHub = IShareToken(address(deployA.spokeRegistry().shareToken(POOL_A, SC_1)));
        shareOnSpoke = IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1)));
    }

    function _spokeNonce() internal view returns (uint64 nonce) {
        (,,, nonce) = s.spoke.snapshotQueue().queuedShares(POOL_A, SC_1);
    }

    function _hubNonce() internal view returns (uint64 nonce) {
        (, nonce) = h.holdings.snapshot(POOL_A, SC_1, s.centrifugeId);
    }

    function testBridgeBeforeSyncThenRevoke() public {
        _setUpBothChains();

        // 1. The manager issues shares on the hub chain. Submitting the queue is a separate transaction,
        //    usually run by a keeper, so the hub does not know about them yet.
        vm.prank(BSM);
        spokeHub.issue(POOL_A, SC_1, INVESTOR_A, SHARES);
        assertEq(h.shareClassManager.totalIssuance(POOL_A, SC_1), 0, "hub has not been told about the issuance");

        // 2. The holder bridges them to spoke B. Nothing requires the source chain's queue to be submitted
        //    first.
        vm.prank(INVESTOR_A);
        shareOnHub.approve(address(spokeHub), SHARES);
        vm.prank(INVESTOR_A);
        spokeHub.crosschainTransferShares{value: GAS}(
            s.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), SHARES, HOOK_GAS
        );
        assertEq(shareOnSpoke.totalSupply(), SHARES, "shares minted on spoke B");
        assertEq(shareOnHub.totalSupply(), 0, "burned on chain A");

        // As far as the hub is concerned, chain A has now revoked shares it never reported issuing.
        (uint128 chainAIssuances, uint128 chainARevocations) =
            h.shareClassManager.issuancePerNetwork(POOL_A, SC_1, h.centrifugeId);
        assertEq(chainAIssuances, 0);
        assertEq(chainARevocations, SHARES);

        // 3. Normal redemption on spoke B: the manager takes the shares and revokes them.
        vm.prank(INVESTOR_A);
        shareOnSpoke.transfer(BSM, SHARES);
        vm.startPrank(BSM);
        shareOnSpoke.approve(address(s.spoke), SHARES);
        s.spoke.revoke(POOL_A, SC_1, SHARES);

        // 4. Spoke B submits its queue. The hub accepts the revocation instead of reverting on it, so the
        //    message lands and the two nonces stay in step.
        s.spoke.submitQueuedShares{value: GAS}(POOL_A, SC_1, 0, REFUND);
        vm.stopPrank();

        assertEq(_hubNonce(), _spokeNonce(), "the hub accepted the message, so the spoke can keep reporting");

        vm.expectRevert(IShareClassManager.NegativeIssuance.selector);
        h.shareClassManager.totalIssuance(POOL_A, SC_1);

        (uint128 issuances, uint128 revocations) = h.shareClassManager.issuanceAcrossNetworks(POOL_A, SC_1);
        assertEq(issuances, SHARES, "only the shares arriving on spoke B were ever reported");
        assertEq(revocations, 2 * SHARES, "the bridge off chain A, plus spoke B's revocation");

        // 5. Chain A finally submits the issuance from step 1, and the totals match the real supply again.
        vm.prank(BSM);
        spokeHub.submitQueuedShares{value: GAS}(POOL_A, SC_1, 0, REFUND);

        assertEq(h.shareClassManager.totalIssuance(POOL_A, SC_1), 0, "the hub and the spoke agree again");
        assertEq(h.shareClassManager.issuance(POOL_A, SC_1, h.centrifugeId), 0);
        assertEq(shareOnSpoke.totalSupply(), 0);
    }

    /// Asset reporting uses the same nonce sequence, so a share message that got stuck would block it too.
    function testAssetAccountingKeepsFlowing() public {
        testBridgeBeforeSyncThenRevoke();

        uint128 amount = 250_000e6;
        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, amount);

        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), amount);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, amount);
        s.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, 0, REFUND);
        vm.stopPrank();

        assertEq(s.usdc.balanceOf(address(s.spoke.escrow(POOL_A))), amount, "assets arrived on spoke B");
        assertEq(h.holdings.amount(POOL_A, SC_1, s.usdcId), amount, "and the hub was told about them");
        assertEq(_hubNonce(), _spokeNonce());
    }
}

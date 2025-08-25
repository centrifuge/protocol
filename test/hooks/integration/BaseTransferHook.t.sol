// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ESCROW_HOOK_ID} from "../../../src/common/interfaces/ITransferHook.sol";

import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";

import {FullDeployer, FullActionBatcher, CommonInput} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../../integration/utils/IntegrationConstants.sol";

contract BaseTransferHookIntegrationTest is FullDeployer, Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = IntegrationConstants.LOCAL_CENTRIFUGE_ID;
    address immutable ADMIN = address(adminSafe);
    uint256 constant GAS = IntegrationConstants.INTEGRATION_DEFAULT_SUBSIDY;
    address constant USER = address(0x1234);

    FullRestrictions public correctHook;
    FullRestrictions public wrongHook;

    function setUp() public {
        CommonInput memory input = CommonInput({
            centrifugeId: LOCAL_CENTRIFUGE_ID,
            adminSafe: adminSafe,
            maxBatchGasLimit: uint128(GAS) * 100,
            version: bytes32(0)
        });

        FullActionBatcher batcher = new FullActionBatcher();
        super.labelAddresses("");
        super.deployFull(input, noAdaptersInput(), batcher);
        super.removeHubDeployerAccess(batcher);

        vm.startPrank(ADMIN);
        correctHook =
            new FullRestrictions(address(root), address(balanceSheet), address(globalEscrow), address(spoke), ADMIN);
        wrongHook = new FullRestrictions(
            address(root), address(asyncRequestManager), address(globalEscrow), address(spoke), ADMIN
        );
        vm.stopPrank();
    }

    function testBalanceSheetBurns() public view {
        assertTrue(
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "balanceSheet burn is fulfillment"
        );
        assertFalse(correctHook.isRedeemClaim(address(balanceSheet), address(0)), "balanceSheet burn not claim");

        assertFalse(
            wrongHook.isRedeemFulfillment(address(balanceSheet), address(0)), "wrong hook: balanceSheet not fulfillment"
        );
        assertTrue(wrongHook.isRedeemClaim(address(balanceSheet), address(0)), "wrong hook: balanceSheet is claim");
    }

    function testAsyncRequestManagerBurns() public view {
        assertFalse(
            correctHook.isRedeemFulfillment(address(asyncRequestManager), address(0)),
            "asyncRequestManager not fulfillment"
        );
        assertTrue(correctHook.isRedeemClaim(address(asyncRequestManager), address(0)), "asyncRequestManager is claim");

        assertTrue(
            wrongHook.isRedeemFulfillment(address(asyncRequestManager), address(0)),
            "wrong hook: asyncRequestManager is fulfillment"
        );
        assertFalse(
            wrongHook.isRedeemClaim(address(asyncRequestManager), address(0)),
            "wrong hook: asyncRequestManager not claim"
        );
    }

    function testDeployedHookUsesBalanceSheet() public view {
        FullRestrictions deployed = fullRestrictionsHook;

        assertEq(deployed.redeemSource(), address(balanceSheet), "deployed hook uses balanceSheet");
        assertTrue(deployed.redeemSource() != address(asyncRequestManager), "deployed hook not asyncRequestManager");
        assertTrue(
            deployed.isRedeemFulfillment(address(balanceSheet), address(0)),
            "deployed hook: balanceSheet is fulfillment"
        );
    }

    function testArchitecturalBugDetection() public view {
        assertFalse(
            wrongHook.isRedeemFulfillment(address(balanceSheet), address(0)), "wrong hook misses balanceSheet burns"
        );
        assertTrue(
            wrongHook.isRedeemClaim(address(balanceSheet), address(0)), "wrong hook treats balanceSheet as claim"
        );
    }

    function testDepositFlow() public view {
        assertTrue(
            correctHook.isDepositFulfillment(address(0), address(globalEscrow)), "mint to globalEscrow is fulfillment"
        );
        assertTrue(correctHook.isDepositClaim(address(globalEscrow), USER), "globalEscrow to user is claim");
        assertTrue(correctHook.isDepositRequest(address(0), USER), "mint to user is request");
    }

    function testRedeemFlow() public view {
        assertTrue(correctHook.isRedeemRequest(USER, ESCROW_HOOK_ID), "user to escrow is request");
        assertTrue(
            correctHook.isDepositClaim(address(globalEscrow), address(asyncRequestManager)),
            "globalEscrow to asyncRequestManager is claim"
        );
        assertTrue(
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "balanceSheet burn is fulfillment"
        );
    }

    function testRevokeShares() public view {
        assertTrue(
            correctHook.isDepositClaim(address(globalEscrow), address(asyncRequestManager)),
            "globalEscrow to asyncRequestManager classified correctly"
        );
        assertTrue(
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "balanceSheet burn classified correctly"
        );

        assertFalse(
            wrongHook.isRedeemFulfillment(address(balanceSheet), address(0)),
            "wrong hook misses balanceSheet fulfillment"
        );
        assertTrue(
            wrongHook.isRedeemFulfillment(address(asyncRequestManager), address(0)),
            "wrong hook incorrectly treats asyncRequestManager as fulfillment"
        );
    }

    function testCompleteInvestmentFlowSequence() public view {
        assertTrue(correctHook.isDepositFulfillment(address(0), address(globalEscrow)), "deposit: mint to globalEscrow");
        assertTrue(correctHook.isDepositClaim(address(globalEscrow), USER), "deposit: globalEscrow to user");

        assertTrue(correctHook.isRedeemRequest(USER, ESCROW_HOOK_ID), "redeem: user to escrow");
        assertTrue(
            correctHook.isDepositClaim(address(globalEscrow), address(asyncRequestManager)),
            "redeem: globalEscrow to asyncRequestManager"
        );
        assertTrue(correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "redeem: balanceSheet burn");
    }

    function testCrosschainTransfers() public view {
        assertTrue(correctHook.isCrosschainTransfer(address(spoke), address(0)), "spoke burn is crosschain");
        assertFalse(correctHook.isRedeemFulfillment(address(spoke), address(0)), "spoke burn not fulfillment");
        assertFalse(correctHook.isRedeemClaim(address(spoke), address(0)), "spoke burn not claim");

        assertTrue(wrongHook.isCrosschainTransfer(address(spoke), address(0)), "wrong hook: spoke still crosschain");
        assertFalse(wrongHook.isRedeemFulfillment(address(spoke), address(0)), "wrong hook: spoke not fulfillment");
        assertFalse(wrongHook.isRedeemClaim(address(spoke), address(0)), "wrong hook: spoke not claim");
    }

    function testOtherContractBurns() public view {
        assertTrue(correctHook.isRedeemClaim(address(globalEscrow), address(0)), "globalEscrow burn is claim");

        if (address(vaultRouter) != address(0)) {
            assertTrue(correctHook.isRedeemClaim(address(vaultRouter), address(0)), "vaultRouter burn is claim");
        }
    }

    function testUserToUserTransfers() public view {
        address user2 = address(0x222);

        assertFalse(correctHook.isDepositRequest(USER, user2), "user to user not deposit request");
        assertFalse(correctHook.isDepositFulfillment(USER, user2), "user to user not deposit fulfillment");
        assertFalse(correctHook.isDepositClaim(USER, user2), "user to user not deposit claim");
        assertFalse(correctHook.isRedeemRequest(USER, user2), "user to user not redeem request");
        assertFalse(correctHook.isRedeemFulfillment(USER, user2), "user to user not redeem fulfillment");
        assertFalse(correctHook.isRedeemClaim(USER, user2), "user to user not redeem claim");
        assertFalse(correctHook.isCrosschainTransfer(USER, user2), "user to user not cross-chain");
    }
}

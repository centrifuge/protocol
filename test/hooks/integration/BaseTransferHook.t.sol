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
        correctHook = new FullRestrictions(
            address(root), address(root), address(balanceSheet), address(globalEscrow), address(spoke), ADMIN
        );
        vm.stopPrank();
    }

    function testBalanceSheetBurns() public view {
        assertTrue(
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "balanceSheet burn is fulfillment"
        );
        assertFalse(
            correctHook.isRedeemClaimOrRevocation(address(balanceSheet), address(0)), "balanceSheet burn not revocation"
        );
    }

    function testAsyncRequestManagerBurns() public view {
        assertFalse(
            correctHook.isRedeemFulfillment(address(asyncRequestManager), address(0)),
            "asyncRequestManager not fulfillment"
        );
        assertTrue(
            correctHook.isRedeemClaimOrRevocation(address(asyncRequestManager), address(0)),
            "asyncRequestManager is revocation"
        );
    }

    function testConfigurationValidation() public view {
        FullRestrictions deployed = fullRestrictionsHook;

        assertEq(deployed.redeemSource(), address(balanceSheet), "hook must use balanceSheet as redeemSource");
        assertTrue(
            deployed.redeemSource() != address(asyncRequestManager),
            "hook must not use asyncRequestManager as redeemSource"
        );

        assertTrue(
            deployed.isRedeemFulfillment(address(balanceSheet), address(0)),
            "balanceSheet burns must be classified as fulfillments"
        );
        assertTrue(
            deployed.isRedeemClaimOrRevocation(address(asyncRequestManager), address(0)),
            "asyncRequestManager burns must be classified as revocations"
        );

        assertTrue(
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0))
                == deployed.isRedeemFulfillment(address(balanceSheet), address(0)),
            "correctHook and deployed hook must have identical classification"
        );
    }

    function testDepositFlow() public view {
        assertTrue(
            correctHook.isDepositFulfillment(address(0), address(globalEscrow)), "mint to globalEscrow is fulfillment"
        );
        assertTrue(correctHook.isDepositClaim(address(globalEscrow), USER), "globalEscrow to user is claim");
        assertTrue(correctHook.isDepositRequestOrIssuance(address(0), USER), "mint to user is issuance");
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
        assertFalse(correctHook.isRedeemClaimOrRevocation(address(spoke), address(0)), "spoke burn not revocation");
    }

    function testOtherContractBurns() public view {
        assertTrue(
            correctHook.isRedeemClaimOrRevocation(address(globalEscrow), address(0)), "globalEscrow burn is revocation"
        );

        if (address(vaultRouter) != address(0)) {
            assertTrue(
                correctHook.isRedeemClaimOrRevocation(address(vaultRouter), address(0)),
                "vaultRouter burn is revocation"
            );
        }
    }

    function testUserToUserTransfers() public view {
        address user2 = address(0x222);

        assertFalse(correctHook.isDepositRequestOrIssuance(USER, user2), "user to user not issuance");
        assertFalse(correctHook.isDepositFulfillment(USER, user2), "user to user not deposit fulfillment");
        assertFalse(correctHook.isDepositClaim(USER, user2), "user to user not deposit claim");
        assertFalse(correctHook.isRedeemRequest(USER, user2), "user to user not redeem request");
        assertFalse(correctHook.isRedeemFulfillment(USER, user2), "user to user not redeem fulfillment");
        assertFalse(correctHook.isRedeemClaimOrRevocation(USER, user2), "user to user not revocation");
        assertFalse(correctHook.isCrosschainTransfer(USER, user2), "user to user not cross-chain");
    }
}

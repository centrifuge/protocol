// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";

import {FullRestrictions} from "../../../src/token/hooks/FullRestrictions.sol";

import {DeployerInput, FullDeployer, noAdaptersInput, defaultTxLimits} from "../../../script/deploy/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {ESCROW_HOOK_ID} from "../../../src/token/interfaces/ITransferHook.sol";

contract BaseTransferHookIntegrationTest is FullDeployer, Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = IntegrationConstants.LOCAL_CENTRIFUGE_ID;
    uint256 constant GAS = IntegrationConstants.INTEGRATION_DEFAULT_SUBSIDY;
    address constant USER = address(0x1234);
    PoolId constant TEST_POOL_ID = PoolId.wrap(999);

    FullRestrictions public correctHook;
    address public poolEscrow;

    function setUp() public {
        address[] memory executors = new address[](1);
        executors[0] = address(this);

        // This contract is the namespace of its own namespace, and its own executor
        super.deployFullBothPhases(
            DeployerInput({
                centrifugeId: LOCAL_CENTRIFUGE_ID,
                deploymentId: "",
                txLimits: defaultTxLimits(),
                protocolSafe: ISafe(makeAddr("ProtocolSafe")),
                opsSafe: ISafe(makeAddr("OpsSafe")),
                root: address(0),
                delay: 0,
                adapters: noAdaptersInput()
            }),
            address(this),
            executors
        );

        vm.prank(address(spokeHandler));
        poolEscrow = address(poolEscrowFactory.newEscrow(TEST_POOL_ID));

        vm.startPrank(address(protocolGuardian.safe()));
        correctHook = new FullRestrictions(
            address(root),
            address(envoy),
            address(spokeRegistry),
            address(spoke),
            address(spokeHandler),
            address(protocolGuardian.safe()),
            address(poolEscrowFactory)
        );
        vm.stopPrank();
    }

    function testBalanceSheetBurns() public view {
        assertTrue(correctHook.isRedeemFulfillment(address(spoke), address(0)), "balanceSheet burn is fulfillment");
        assertFalse(
            correctHook.isRedeemClaimOrRevocation(address(spoke), address(0)), "balanceSheet burn not revocation"
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

        assertEq(address(deployed.spoke()), address(spoke), "hook must use balanceSheet");
        assertTrue(
            address(deployed.spoke()) != address(asyncRequestManager),
            "hook must not use asyncRequestManager as balanceSheet"
        );

        assertTrue(
            deployed.isRedeemFulfillment(address(spoke), address(0)),
            "balanceSheet burns must be classified as fulfillments"
        );
        assertTrue(
            deployed.isRedeemClaimOrRevocation(address(asyncRequestManager), address(0)),
            "asyncRequestManager burns must be classified as revocations"
        );

        assertTrue(
            correctHook.isRedeemFulfillment(address(spoke), address(0))
                == deployed.isRedeemFulfillment(address(spoke), address(0)),
            "correctHook and deployed hook must have identical classification"
        );
    }

    function testDepositFlow() public view {
        assertTrue(correctHook.isDepositFulfillment(address(0), poolEscrow), "mint to PoolEscrow is fulfillment");
        assertTrue(correctHook.isDepositClaim(poolEscrow, USER), "transfer from PoolEscrow to user is claim");
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), USER), "mint to non-endorsed user is direct issuance"
        );
    }

    function testRedeemFlow() public view {
        assertTrue(correctHook.isRedeemRequest(USER, ESCROW_HOOK_ID), "user to escrow is request");
        assertTrue(correctHook.isRedeemFulfillment(address(spoke), address(0)), "balanceSheet burn is fulfillment");
        assertTrue(correctHook.isRedeemClaimOrRevocation(USER, address(0)), "user burn is redeem claim");
    }

    function testRevokeShares() public view {
        assertFalse(
            correctHook.isDepositFulfillment(address(0), address(asyncRequestManager)),
            "mint to AsyncRequestManager (endorsed but not poolEscrow) is NOT fulfillment"
        );
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), address(asyncRequestManager)),
            "mint to AsyncRequestManager is direct issuance"
        );
        assertFalse(
            correctHook.isDepositClaim(address(asyncRequestManager), USER),
            "AsyncRequestManager to user is NOT a deposit claim (not from poolEscrow)"
        );
        assertTrue(
            correctHook.isRedeemFulfillment(address(spoke), address(0)), "balanceSheet burn classified correctly"
        );
    }

    function testCompleteInvestmentFlowSequence() public view {
        assertTrue(
            correctHook.isDepositFulfillment(address(0), poolEscrow), "deposit: mint to PoolEscrow is fulfillment"
        );
        assertTrue(correctHook.isDepositClaim(poolEscrow, USER), "deposit: PoolEscrow to user is claim");

        assertTrue(correctHook.isDepositRequestOrIssuance(address(0), USER), "mint to user is direct issuance");

        assertTrue(correctHook.isRedeemRequest(USER, ESCROW_HOOK_ID), "redeem: user to escrow");
        assertTrue(correctHook.isRedeemFulfillment(address(spoke), address(0)), "redeem: balanceSheet burn");

        assertFalse(
            correctHook.isDepositClaim(address(spoke), address(asyncRequestManager)),
            "internal: balanceSheet to asyncRequestManager not a claim"
        );
    }

    function testCrosschainTransfers() public view {
        assertTrue(
            correctHook.isCrosschainTransfer(address(spokeHandler), address(0)), "spokeHandler burn is crosschain"
        );
        assertFalse(
            correctHook.isRedeemFulfillment(address(spokeHandler), address(0)), "spokeHandler burn not fulfillment"
        );
        assertFalse(
            correctHook.isRedeemClaimOrRevocation(address(spokeHandler), address(0)), "spokeHandler burn not revocation"
        );
    }

    function testOtherContractBurns() public view {
        // Positive cases: burns from contracts that are neither balanceSheet nor crosschainSource
        assertTrue(
            correctHook.isRedeemClaimOrRevocation(address(asyncRequestManager), address(0)),
            "asyncRequestManager burn is revocation"
        );
        assertTrue(
            correctHook.isRedeemClaimOrRevocation(address(poolEscrow), address(0)), "poolEscrow burn is revocation"
        );
        if (address(vaultRouter) != address(0)) {
            assertTrue(
                correctHook.isRedeemClaimOrRevocation(address(vaultRouter), address(0)),
                "vaultRouter burn is revocation: endorsed and neither balanceSheet nor crosschainSource"
            );
        }

        // Negative cases: burns from special contracts (spoke redemption source and crosschainSource)
        assertFalse(correctHook.isRedeemClaimOrRevocation(address(spoke), address(0)), "spoke burn is not revocation");
        assertFalse(
            correctHook.isRedeemClaimOrRevocation(address(spokeHandler), address(0)),
            "spokeHandler (crosschainSource) burn is not revocation"
        );
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

    function testInternalProtocolTransfers() public view {
        assertFalse(
            correctHook.isDepositClaim(address(spoke), address(vaultRouter)), "balanceSheet to vaultRouter is internal"
        );
        assertFalse(
            correctHook.isDepositClaim(address(asyncRequestManager), address(vaultRouter)),
            "asyncRequestManager to vaultRouter is internal"
        );
        assertFalse(
            correctHook.isDepositClaim(address(vaultRouter), address(asyncRequestManager)),
            "vaultRouter to asyncRequestManager is internal"
        );
        assertTrue(
            correctHook.isDepositClaim(poolEscrow, address(spoke)), "poolEscrow to balanceSheet is a deposit claim"
        );

        assertFalse(correctHook.isDepositClaim(address(spoke), USER), "balanceSheet to user is NOT a deposit claim");
        assertFalse(
            correctHook.isDepositClaim(address(vaultRouter), USER), "vaultRouter to user is NOT a deposit claim"
        );

        assertFalse(correctHook.isDepositClaim(USER, address(spoke)), "user to balanceSheet is not claim");
        assertFalse(
            correctHook.isDepositClaim(USER, address(asyncRequestManager)), "user to asyncRequestManager is not claim"
        );
        assertFalse(correctHook.isDepositClaim(USER, poolEscrow), "user to poolEscrow is not claim");

        assertFalse(
            correctHook.isDepositFulfillment(address(0), address(spoke)),
            "mint to balanceSheet (endorsed but not poolEscrow) is NOT fulfillment"
        );
        assertFalse(
            correctHook.isDepositFulfillment(address(0), address(vaultRouter)),
            "mint to vaultRouter (endorsed but not poolEscrow) is NOT fulfillment"
        );
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), address(spoke)),
            "mint to balanceSheet is direct issuance"
        );
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), address(vaultRouter)),
            "mint to vaultRouter is direct issuance"
        );
    }

    function testEndorsementVerification(address notEndorsed) public view {
        // Every account the deployment endorses, or the fuzzer eventually offers one of them as the
        // account that should not be endorsed
        vm.assume(
            notEndorsed != address(spoke) && notEndorsed != address(asyncRequestManager)
                && notEndorsed != address(vaultRouter) && notEndorsed != address(tokenBridge)
                && notEndorsed != address(shareManager) && notEndorsed != poolEscrow
        );

        assertTrue(root.endorsed(address(spoke)), "spoke must be endorsed");
        assertTrue(root.endorsed(address(asyncRequestManager)), "asyncRequestManager must be endorsed");
        assertTrue(root.endorsed(address(vaultRouter)), "vaultRouter must be endorsed");
        assertTrue(root.endorsed(address(tokenBridge)), "tokenBridge must be endorsed");
        assertTrue(root.endorsed(address(shareManager)), "shareManager must be endorsed");

        assertFalse(root.endorsed(poolEscrow));
        assertFalse(root.endorsed(notEndorsed));
    }
}

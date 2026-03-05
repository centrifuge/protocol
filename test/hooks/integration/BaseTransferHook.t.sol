// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ESCROW_HOOK_ID} from "../../../src/core/spoke/interfaces/ITransferHook.sol";

import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";

import {
    FullActionBatcher,
    FullDeployer,
    FullInput,
    noAdaptersInput,
    defaultTxLimits,
    CoreInput
} from "../../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../../integration/utils/IntegrationConstants.sol";

contract MockPoolEscrow {
    PoolId public immutable poolId;

    constructor(PoolId poolId_) {
        poolId = poolId_;
    }
}

contract BaseTransferHookIntegrationTest is FullDeployer, Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = IntegrationConstants.LOCAL_CENTRIFUGE_ID;
    address immutable ADMIN = address(protocolSafe);
    uint256 constant GAS = IntegrationConstants.INTEGRATION_DEFAULT_SUBSIDY;
    address constant USER = address(0x1234);
    PoolId constant TEST_POOL_ID = PoolId.wrap(999);

    FullRestrictions public correctHook;
    address public poolEscrow;

    function setUp() public {
        FullActionBatcher batcher = new FullActionBatcher(address(this));
        super.labelAddresses("");
        super.deployFull(
            FullInput({
                core: CoreInput({centrifugeId: LOCAL_CENTRIFUGE_ID, version: bytes32(0), txLimits: defaultTxLimits()}),
                protocolSafe: protocolSafe,
                opsSafe: protocolSafe,
                adapters: noAdaptersInput()
            }),
            batcher
        );

        MockPoolEscrow mockPoolEscrow = new MockPoolEscrow(TEST_POOL_ID);
        poolEscrow = address(mockPoolEscrow);
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(bytes4(keccak256("escrow(uint64)")), TEST_POOL_ID),
            abi.encode(poolEscrow)
        );

        super.removeFullDeployerAccess(batcher);

        vm.startPrank(ADMIN);
        correctHook = new FullRestrictions(
            address(root),
            address(spoke),
            address(balanceSheet),
            address(spoke),
            ADMIN,
            address(poolEscrowFactory),
            poolEscrow
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

        assertEq(address(deployed.balanceSheet()), address(balanceSheet), "hook must use balanceSheet");
        assertTrue(
            address(deployed.balanceSheet()) != address(asyncRequestManager),
            "hook must not use asyncRequestManager as balanceSheet"
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
        assertTrue(correctHook.isDepositFulfillment(address(0), poolEscrow), "mint to PoolEscrow is fulfillment");
        assertTrue(correctHook.isDepositClaim(poolEscrow, USER), "transfer from PoolEscrow to user is claim");
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), USER), "mint to non-endorsed user is direct issuance"
        );
    }

    function testRedeemFlow() public view {
        assertTrue(correctHook.isRedeemRequest(USER, ESCROW_HOOK_ID), "user to escrow is request");
        assertTrue(
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "balanceSheet burn is fulfillment"
        );
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
            correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "balanceSheet burn classified correctly"
        );
    }

    function testCompleteInvestmentFlowSequence() public view {
        assertTrue(
            correctHook.isDepositFulfillment(address(0), poolEscrow), "deposit: mint to PoolEscrow is fulfillment"
        );
        assertTrue(correctHook.isDepositClaim(poolEscrow, USER), "deposit: PoolEscrow to user is claim");

        assertTrue(correctHook.isDepositRequestOrIssuance(address(0), USER), "mint to user is direct issuance");

        assertTrue(correctHook.isRedeemRequest(USER, ESCROW_HOOK_ID), "redeem: user to escrow");
        assertTrue(correctHook.isRedeemFulfillment(address(balanceSheet), address(0)), "redeem: balanceSheet burn");

        assertFalse(
            correctHook.isDepositClaim(address(balanceSheet), address(asyncRequestManager)),
            "internal: balanceSheet to asyncRequestManager not a claim"
        );
    }

    function testCrosschainTransfers() public view {
        assertTrue(correctHook.isCrosschainTransfer(address(spoke), address(0)), "spoke burn is crosschain");
        assertFalse(correctHook.isRedeemFulfillment(address(spoke), address(0)), "spoke burn not fulfillment");
        assertFalse(correctHook.isRedeemClaimOrRevocation(address(spoke), address(0)), "spoke burn not revocation");
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

        // Negative cases: burns from special contracts (balanceSheet and crosschainSource)
        assertFalse(
            correctHook.isRedeemClaimOrRevocation(address(balanceSheet), address(0)),
            "balanceSheet burn is not revocation"
        );
        assertFalse(
            correctHook.isRedeemClaimOrRevocation(address(spoke), address(0)),
            "spoke (crosschainSource) burn is not revocation"
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
            correctHook.isDepositClaim(address(balanceSheet), address(vaultRouter)),
            "balanceSheet to vaultRouter is internal"
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
            correctHook.isDepositClaim(poolEscrow, address(balanceSheet)),
            "poolEscrow to balanceSheet is a deposit claim"
        );

        assertFalse(
            correctHook.isDepositClaim(address(balanceSheet), USER), "balanceSheet to user is NOT a deposit claim"
        );
        assertFalse(
            correctHook.isDepositClaim(address(vaultRouter), USER), "vaultRouter to user is NOT a deposit claim"
        );

        assertFalse(correctHook.isDepositClaim(USER, address(balanceSheet)), "user to balanceSheet is not claim");
        assertFalse(
            correctHook.isDepositClaim(USER, address(asyncRequestManager)), "user to asyncRequestManager is not claim"
        );
        assertFalse(correctHook.isDepositClaim(USER, poolEscrow), "user to poolEscrow is not claim");

        assertFalse(
            correctHook.isDepositFulfillment(address(0), address(balanceSheet)),
            "mint to balanceSheet (endorsed but not poolEscrow) is NOT fulfillment"
        );
        assertFalse(
            correctHook.isDepositFulfillment(address(0), address(vaultRouter)),
            "mint to vaultRouter (endorsed but not poolEscrow) is NOT fulfillment"
        );
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), address(balanceSheet)),
            "mint to balanceSheet is direct issuance"
        );
        assertTrue(
            correctHook.isDepositRequestOrIssuance(address(0), address(vaultRouter)),
            "mint to vaultRouter is direct issuance"
        );
    }

    function testEndorsementVerification(address notEndorsed) public view {
        vm.assume(
            notEndorsed != address(balanceSheet) && notEndorsed != address(asyncRequestManager)
                && notEndorsed != address(vaultRouter) && notEndorsed != poolEscrow
        );

        assertTrue(root.endorsed(address(balanceSheet)), "balanceSheet must be endorsed");
        assertTrue(root.endorsed(address(asyncRequestManager)), "asyncRequestManager must be endorsed");
        assertTrue(root.endorsed(address(vaultRouter)), "vaultRouter must be endorsed");

        assertFalse(root.endorsed(poolEscrow));
        assertFalse(root.endorsed(notEndorsed));
    }
}

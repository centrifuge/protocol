// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {ISafe} from "../../../src/admin/interfaces/ISafe.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";
import {IShareTokenHook} from "../../../src/token/hooks/interfaces/IShareTokenHook.sol";

import {DeployerInput, FullDeployer, noAdaptersInput, defaultTxLimits} from "../../../script/deploy/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {HookData} from "../../../src/token/interfaces/ITransferHook.sol";

contract ShareTokenHookIntegrationTest is FullDeployer, Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = IntegrationConstants.LOCAL_CENTRIFUGE_ID;
    uint256 constant GAS = IntegrationConstants.INTEGRATION_DEFAULT_SUBSIDY;
    address constant USER = address(0x1234);
    address constant ACTOR_A = address(0xAC7A1);
    address constant ACTOR_B = address(0xAC7A2);
    PoolId constant TEST_POOL_ID = PoolId.wrap(999);

    ShareTokenHook public correctHook;
    address public escrow;

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
                vaults: true,
                adapters: noAdaptersInput()
            }),
            address(this),
            executors
        );

        vm.prank(address(spokeHandler));
        escrow = address(escrowFactory.newEscrow(TEST_POOL_ID));

        vm.startPrank(address(protocolGuardian.safe()));
        correctHook = new ShareTokenHook(
            address(root),
            address(envoy),
            address(spokeRegistry),
            address(spoke),
            address(spokeHandler),
            address(protocolGuardian.safe()),
            address(escrowFactory),
            HookPolicies.fullRestrictions()
        );
        vm.stopPrank();
    }

    function testConfigurationValidation() public {
        assertEq(address(fullRestrictionsHook.spoke()), address(spoke), "hook must use the spoke");
        assertEq(
            uint8(fullRestrictionsHook.leg(address(spoke), address(0))),
            uint8(IShareTokenHook.Kind.Fulfill),
            "the spoke's burn is a fulfillment"
        );
        assertEq(
            uint8(fullRestrictionsHook.leg(makeAddr("nonSpokeBurner"), address(0))),
            uint8(IShareTokenHook.Kind.Burn),
            "another burner is a holder's own burn"
        );
    }

    /// @dev The lifecycle moves of a deployment, each classified from its endpoints alone.
    function testLegsOfTheLifecycle() public view {
        _assertLeg(address(0), USER, IShareTokenHook.Kind.Mint);
        _assertLeg(address(0), address(spoke), IShareTokenHook.Kind.Mint);
        _assertLeg(address(0), escrow, IShareTokenHook.Kind.Transfer);

        _assertLeg(escrow, USER, IShareTokenHook.Kind.Release);
        _assertLeg(escrow, address(spoke), IShareTokenHook.Kind.Release);
        _assertLeg(address(spoke), USER, IShareTokenHook.Kind.Transfer);
        _assertLeg(ACTOR_A, ACTOR_B, IShareTokenHook.Kind.Transfer);

        _assertLeg(address(spoke), address(0), IShareTokenHook.Kind.Fulfill);
        _assertLeg(USER, address(0), IShareTokenHook.Kind.Burn);
        _assertLeg(escrow, address(0), IShareTokenHook.Kind.Burn);
        _assertLeg(address(spokeHandler), address(0), IShareTokenHook.Kind.Transfer);

        // The outbound leg is the destination chain encoded as an address
        _assertLeg(USER, address(uint160(LOCAL_CENTRIFUGE_ID)), IShareTokenHook.Kind.Transfer);
    }

    /// @dev An inbound cross-chain transfer mints to the spoke handler before it passes the shares on, and the hook
    ///      checks that mint as a transfer, so the handler has to pass `transfer` without being a member.
    function testTheSpokeHandlerReceivesAnInboundMintUnderFullRestrictions() public {
        HookDataToken token = new HookDataToken();

        vm.prank(address(token));
        assertTrue(correctHook.checkERC20Transfer(address(0), address(spokeHandler), 1, HookData(0, 0)));

        vm.prank(address(token));
        assertFalse(correctHook.checkERC20Transfer(address(0), makeAddr("stranger"), 1, HookData(0, 0)));
    }

    function _assertLeg(address from, address to, IShareTokenHook.Kind expected) internal view {
        assertEq(uint8(correctHook.leg(from, to)), uint8(expected));
    }

    /// @dev Every endorsed address must be enumerated here: the fuzzer seeds its address dictionary from
    ///      observed state, so a missing one is found rather than missed.
    function testEndorsementVerification(address notEndorsed) public view {
        // Every account the deployment endorses, or the fuzzer eventually offers one of them as the
        // account that should not be endorsed
        vm.assume(
            notEndorsed != address(spoke) && notEndorsed != address(spokeHandler) && notEndorsed != address(tokenBridge)
                && notEndorsed != address(shareManager) && notEndorsed != escrow
        );

        assertTrue(root.endorsed(address(spoke)), "spoke must be endorsed");
        assertTrue(root.endorsed(address(spokeHandler)), "spokeHandler must be endorsed");
        assertTrue(root.endorsed(address(tokenBridge)), "tokenBridge must be endorsed");
        assertTrue(root.endorsed(address(shareManager)), "shareManager must be endorsed");

        assertFalse(root.endorsed(escrow));
        assertFalse(root.endorsed(notEndorsed));
    }
}

/// @dev Answers the hook's reads of a share token with an empty memberlist entry for everyone.
contract HookDataToken {
    function hookDataOf(address) external pure returns (bytes16) {
        return bytes16(0);
    }
}

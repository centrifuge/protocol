// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CryticToFoundry} from "./CryticToFoundry.sol";

/// @dev Drives each assurance handler once with state it can act on and asserts it went through, so a setup change
///      that turns one into a silent revert fails here, and a src mutation can be shown to fail the check.
contract AssuranceReachability is CryticToFoundry {
    function _fund() internal {
        vault_instantDeposit(0, false, 300e6, false);
        vault_instantDeposit(1, false, 300e6, false);
        vault_instantDeposit(0, true, 300e6, false);
    }

    function testAssurance_tradeDepositForOther() public {
        vault_instantTradeFor(0, 1, false, 50e6, 0);
        assertGt(ok["vault_instantTradeFor"], 0, "not reached");
        _assertNoFailures();
        vault_instantTradeFor(0, 1, false, 5e18, 1);
        _assertNoFailures();
        assertEq(ok["vault_instantTradeFor"], 2, "mint not reached");
    }

    function testAssurance_tradeRedeemForOther() public {
        _fund();
        vault_instantTradeFor(0, 1, false, 5e17, 3);
        vault_instantTradeFor(0, 2, false, 5e5, 2);
        assertEq(ok["vault_instantTradeFor"], 2, "redeem not reached");
        _assertNoFailures();
    }

    function testAssurance_overMax() public {
        _fund();
        for (uint8 k; k < 4; k++) {
            vault_overMaxRefused(0, false, k);
            vault_overMaxRefused(0, true, k);
        }
        assertGt(ok["vault_overMaxRefused"], 3, "over max not reached");
        _assertNoFailures();
    }

    function testAssurance_claimConverted() public {
        vault_requestDeposit(0, 0, 0, 1_000e6);
        hub_fulfill(0, 0, true);
        vault_claimMaxConverted(0, 0, true);
        assertGt(ok["vault_claimMaxDeposit"], 0, "deposit(maxDeposit) not reached");
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);
        vault_claimMaxConverted(0, 0, false);
        assertGt(ok["vault_claimMaxRedeem"], 0, "redeem(maxRedeem) not reached");
        _assertNoFailures();
    }

    function testAssurance_ledgerDelta() public {
        vault_requestDeposit(0, 0, 0, 1_000e6);
        hub_fulfill(0, 0, true);
        vault_claimDeposit(0, 0, 1e6 + 1, true);
        vault_claimDeposit(0, 0, 1e6 + 1, false);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);
        vault_claimRedeem(0, 0, 1e6 + 1, true);
        vault_claimRedeem(0, 0, 1e6 + 1, false);
        _assertNoFailures();
    }

    function testAssurance_operators() public {
        vault_instantDeposit(0, false, 300e6, false);
        vault_operatorRequests(0, 1, 2, 0, 10e6, true);
        assertGt(ok["vault_operatorRequests"], 0, "operator deposit request not reached");
        vault_operatorRequests(0, 1, 2, 1, 5e17, false);
        assertEq(ok["vault_operatorRequests"], 2, "operator redeem request not reached");
        vault_allowanceRequestRedeem(0, 1, 1, 3e17, 2e17);
        vault_allowanceRequestRedeem(0, 1, 1, 1e17, 2e17);
        assertEq(ok["vault_allowanceRequestRedeem"], 2, "allowance request not reached");
        _assertNoFailures();
    }

    function testAssurance_operatorClaims() public {
        vault_requestDeposit(0, 0, 0, 1_000e6);
        hub_fulfill(0, 0, true);
        vault_operatorClaimsForOthers(0, 1, 2, 0, 10e6, 0);
        vault_operatorClaimsForOthers(0, 1, 2, 0, 10e18, 1);
        assertEq(ok["vault_operatorClaimsForOthers"], 2, "operator claims not reached");
        vault_claimMax(0, 0, true);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);
        vault_operatorClaimsForOthers(0, 1, 2, 0, 1e6, 2);
        vault_operatorClaimsForOthers(0, 1, 2, 0, 1e18, 3);
        assertEq(ok["vault_operatorClaimsForOthers"], 4, "operator redeem claims not reached");
        _assertNoFailures();
    }

    function testAssurance_operatorCannotTrade() public {
        for (uint8 k; k < 4; k++) {
            vault_operatorCannotTrade(0, 1, 2, 1e6, k);
        }
        assertEq(ok["vault_operatorCannotTrade"], 4, "operator refusal not reached");
        _assertNoFailures();
    }

    function testAssurance_strangers() public {
        vault_requestDeposit(0, 0, 0, 1_000e6);
        hub_fulfill(0, 0, true);
        for (uint8 k; k < 4; k++) {
            vault_strangerCannotClaimFor(0, 0, 1e6, k);
            vault_strangerCannotClaimFor(0, 0, 1e6, k + 12);
        }
        assertGt(ok["vault_strangerCannotClaimFor"], 3, "stranger claim not reached");
        vault_claimMax(0, 0, true);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);
        for (uint8 k; k < 4; k++) {
            vault_strangerCannotClaimFor(0, 0, 1e6, k);
        }
        vault_strangerCannotRequestFor(0, 0, 1e6, 0);
        vault_strangerCannotRequestFor(0, 0, 1e6, 1);
        assertEq(ok["vault_strangerCannotRequestFor"], 2, "stranger request not reached");
        _assertNoFailures();
    }

    function testAssurance_donate() public {
        _fund();
        vault_donate(10e6);
        assertEq(ok["vault_donate"], 1, "donate not reached");
        _assertNoFailures();
        assertProperties();
    }

    function testAssurance_propertiesRedeemClaim() public {
        vault_requestDeposit(0, 0, 0, 1_000e6);
        hub_fulfill(0, 0, true);
        vault_claimMax(0, 0, true);
        vault_requestRedeem(0, 0, 0, shareA.balanceOf(actors[0]) / 2);
        hub_fulfill(1, 0, true);
        assertProperties();
    }

    function testAssurance_propertiesUnlinked() public {
        _fund();
        hub_setVaultLink(2, false);
        assertProperties();
    }

    function testAssurance_properties() public {
        _fund();
        vault_requestDeposit(0, 0, 0, 1_000e6);
        hub_fulfill(0, 0, true);
        assertProperties();
        hub_freeze(0);
        assertProperties();
        hub_unfreeze();
        hub_setVaultLink(2, false);
        assertProperties();
        hub_setVaultLink(2, true);
        policy_configure(0, 100, 0, 0, false);
        assertProperties();
        policy_configure(0, 100, 7, 1, false);
        assertProperties();
        hub_lapseMember(1, 0, false);
        hub_warp(1 hours);
        assertProperties();
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ledgerDerivationPath} from "./Ledger.s.sol";

import {DEPLOY_GATE_ADDRESS} from "create3-gate/script/DeployGate.d.sol";
import {DeployGateScript} from "create3-gate/script/DeployGateScript.sol";

import {Safe} from "safe-utils/Safe.sol";

/// @title  GateProposalScript
/// @notice Reaches the DeployGate through a Safe — one that holds a namespace, or one a namespace named as
///         its delegate: one plain call into a gate already on the chain, which is what the owners sign.
///
/// @dev    What this repository adds to the gate's own `DeployGateScript`, which comes from the gate's
///         repository as a dependency (`lib/create3-gate`, imported as `create3-gate/`) rather than being
///         copied into this one: reaching the gate from a Safe is how *this* protocol does it, not something
///         the gate knows about. A script that only deploys through a gate inherits DeployGateScript;
///         a script that has to get a call into the gate *from a Safe* inherits this one.
abstract contract GateProposalScript is DeployGateScript {
    using Safe for *;

    Safe.Client private proposalSafe;
    address private ledgerSigner;

    /// @notice The account on the Ledger, at `LEDGER_DERIVATION_PATH`: the owner or proposer a proposal is
    ///         signed by, which the Safe transaction service requires as the proposal's `sender`.
    /// @dev    Asked of the device rather than passed in, so that `--sender` is free to be the Safe the run
    ///         acts as and the two can never disagree — a proposal whose sender is not its signer is what
    ///         the service rejects. Whether that account may propose is the service's decision, not made
    ///         here. Read once per run: the device answers slowly
    function ledgerAddress() internal returns (address) {
        if (ledgerSigner != address(0)) return ledgerSigner;

        string[] memory inputs = new string[](6);
        inputs[0] = "cast";
        inputs[1] = "wallet";
        inputs[2] = "address";
        inputs[3] = "--ledger";
        inputs[4] = "--mnemonic-derivation-path";
        inputs[5] = ledgerDerivationPath();

        bytes memory out = vm.ffi(inputs);
        require(
            out.length == 20, "cast wallet address --ledger did not answer with an address: is the Ledger connected?"
        );

        ledgerSigner = address(bytes20(out));
        return ledgerSigner;
    }

    /// @notice Checks the gate a Safe is about to reach, without bringing one up.
    /// @dev    A Safe reaches only a gate already on the chain. Putting it there is a step before the deployment,
    ///         taken by another actor: anyone can deploy it, and the namespace names its delegates on it.
    function requireDeployGate() internal view {
        require(
            DEPLOY_GATE_ADDRESS.code.length > 0,
            "No DeployGate on this chain: it is deployed before the deployment, and a Safe commits only through one already there"
        );
        require(isDeployGateDeployed(), "Not the DeployGate: unexpected code at that address");
    }

    /// @notice Proposes one call to the gate through a Safe: a plain call, never a batch, so the transaction
    ///         the owners sign is exactly that call. The single way a Safe reaches the gate, whatever the call.
    ///         Signed by the Ledger, as the owner it holds: see `ledgerAddress`.
    /// @dev    The gate has to be on the chain already: see `requireDeployGate`. The proposal is posted over
    ///         ffi the moment it is signed, while a broadcast is deferred to the end of the run, so a run calling
    ///         this must broadcast nothing — it would post the proposal and then fail to send.
    function proposeGateCall(address safe_, bytes memory gateCall) internal {
        requireDeployGate();

        proposalSafe.initialize(safe_);
        proposalSafe.proposeTransaction(DEPLOY_GATE_ADDRESS, gateCall, ledgerAddress(), ledgerDerivationPath());
    }
}

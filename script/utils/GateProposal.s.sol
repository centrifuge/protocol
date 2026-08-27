// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICreateX} from "./createx/ICreateX.sol";
import {ledgerDerivationPath} from "./Ledger.s.sol";
import {CREATEX_ADDRESS} from "./createx/CreateX.d.sol";

import {DeployGateScript} from "create3-gate/script/DeployGateScript.sol";
import {
    DEPLOY_GATE_SALT,
    DEPLOY_GATE_ADDRESS,
    DEPLOY_GATE_BYTECODE,
    DEPLOY_GATE_EXTCODEHASH
} from "create3-gate/script/DeployGate.d.sol";

import {Safe} from "safe-utils/Safe.sol";

/// @title  EnsureDeployGate
/// @notice `setUpDeployGate` as one on-chain call: deploys the gate when the chain has none, and checks it
///         either way, from a constructor so that a Safe batch can carry it.
/// @dev    What a batch built now but executed later needs. The gate is deployable by anyone, and any
///         `commit()` run brings it up on a chain that lacks one, so deploying it in the batch directly
///         would revert on the taken address whenever someone lands it first — and the multisend would take
///         the gate call behind it down too. This steps aside instead, and what it cannot step aside from it
///         rejects: foreign code at the gate's address fails the batch rather than being committed into.
///         Deployed through plain CREATE, whose address comes from a nonce rather than a salt, so the
///         carrier itself has no address to lose a race over.
contract EnsureDeployGate {
    constructor() {
        if (DEPLOY_GATE_ADDRESS.code.length == 0) {
            ICreateX(CREATEX_ADDRESS).deployCreate2(DEPLOY_GATE_SALT, DEPLOY_GATE_BYTECODE);
        }

        require(DEPLOY_GATE_ADDRESS.codehash == DEPLOY_GATE_EXTCODEHASH, "Not the DeployGate");
    }
}

/// @title  GateProposalScript
/// @notice Reaches the DeployGate through a Safe — one that holds a namespace, or one a namespace named as
///         its delegate: the call the owners sign, with the gate's own deployment riding in the same batch on
///         a chain that has none.
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

    /// @notice Proposes one call to the gate through a Safe, with the gate's own deployment riding in the
    ///         same batch on a chain that has none. The single way a Safe reaches the gate, whatever the call.
    ///         Signed by the Ledger, as the owner it holds: see `ledgerAddress`.
    /// @dev    The proposal is posted over ffi the moment it is signed, while a broadcast is deferred to the
    ///         end of the run, so a run calling this must broadcast nothing — it would post the proposal and
    ///         then fail to send. The batch carries `EnsureDeployGate` rather than the gate's deployment
    ///         itself, so a gate landing between the proposal and its execution leaves the batch working
    ///         instead of reverting it.
    function proposeGateCall(address safe_, bytes memory gateCall) internal {
        // Proves the pieces before the owners sign, in simulated state only: reverts when the chain has no
        // CreateX at all, when foreign code sits at the gate's address, or when the bytecode no longer
        // builds the gate. Read before the setup, which is what puts a gate into the simulation
        bool gateMissing = !isDeployGateDeployed();
        setUpDeployGate();

        address[] memory targets = new address[](gateMissing ? 2 : 1);
        bytes[] memory calls = new bytes[](targets.length);

        if (gateMissing) {
            targets[0] = CREATEX_ADDRESS;
            calls[0] = abi.encodeCall(ICreateX.deployCreate, (type(EnsureDeployGate).creationCode));
        }

        targets[targets.length - 1] = DEPLOY_GATE_ADDRESS;
        calls[targets.length - 1] = gateCall;

        proposalSafe.initialize(safe_);
        proposalSafe.proposeTransactions(targets, calls, ledgerAddress(), ledgerDerivationPath());
    }
}

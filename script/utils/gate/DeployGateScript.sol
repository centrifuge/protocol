// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DEPLOY_GATE_SALT, DEPLOY_GATE_ADDRESS, DEPLOY_GATE_BYTECODE, DEPLOY_GATE_EXTCODEHASH} from "./DeployGate.d.sol";

import {Safe} from "safe-utils/Safe.sol";
import {ICreateX} from "../createx/ICreateX.sol";
import {ledgerDerivationPath} from "../Admin.s.sol";
import {CREATEX_ADDRESS} from "../createx/CreateX.d.sol";
import {CreateXScript} from "../createx/CreateXScript.sol";

/// @title  EnsureDeployGate
/// @notice `setUpDeployGate` as one on-chain call: deploys the gate when the chain has none, and checks it
///         either way, from a constructor so that a Safe batch can carry it.
/// @dev    What a batch built now but executed later needs. The gate is deployable by anyone, and any
///         `validate()` run brings it up on a chain that lacks one, so deploying it in the batch directly
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

/// @title  DeployGateScript
/// @notice Makes sure a chain has its DeployGate, for the scripts that deploy through one: brought up by the
///         run itself where a key signs, or inside the Safe proposal a `proposeGateCall` posts.
///
/// @dev    The same shape as CreateXScript, one level up and for the same reason: the gate is a fixed address
///         a script needs to already be there, so a script makes sure of it rather than depending on someone
///         having run something first. Unlike CreateX it can always be put there, on any chain and by anyone,
///         so there is no case to bail out on. It deploys from DEPLOY_GATE_BYTECODE rather than from the
///         contract, so nothing here depends on the gate's source living in this repository.
abstract contract DeployGateScript is CreateXScript {
    using Safe for *;

    Safe.Client private proposalSafe;

    /// @notice Deploys the DeployGate when the chain does not have one, and checks it when it does
    function setUpDeployGate() internal {
        setUpCreateXFactory();

        if (DEPLOY_GATE_ADDRESS.code.length == 0) {
            CreateX.deployCreate2(DEPLOY_GATE_SALT, DEPLOY_GATE_BYTECODE);
        }

        // A chain that derives addresses its own way is where the constant stops standing for the gate
        require(isDeployGateDeployed(), "Not the DeployGate: unexpected code at that address");

        vm.label(DEPLOY_GATE_ADDRESS, "DeployGate");
    }

    /// @notice Whether the gate is where it belongs, running the code it is supposed to run
    function isDeployGateDeployed() internal view returns (bool) {
        return DEPLOY_GATE_ADDRESS.codehash == DEPLOY_GATE_EXTCODEHASH;
    }

    /// @notice Proposes one call to the gate through a Safe, with the gate's own deployment riding in the
    ///         same batch on a chain that has none. The single way a Safe reaches the gate, whatever the call.
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
        proposalSafe.proposeTransactions(targets, calls, msg.sender, ledgerDerivationPath());
    }
}

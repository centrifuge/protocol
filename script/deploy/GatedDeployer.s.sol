// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DeployGate} from "../../src/deployment/misc/DeployGate.sol";

import {console} from "forge-std/console.sol";

/// @dev How a gated deployment is signed. Both phases need a DeployGate, brought up by DeployGateDeployer.
enum DeployPhase {
    // Commit what may be deployed and who may deploy it: the single transaction the admin signs
    Validate,
    // Deploy what has been committed, one transaction per contract
    Execute
}

/// @notice Deploys through a DeployGate instead of directly: an admin commits what may be deployed, in a
///         single transaction, and the executor it named then deploys it.
contract GatedDeployer is BaseDeployer {
    /// @dev Account signing the run. Not the one addresses derive from, which is the gate
    address public deployer;

    DeployPhase internal deployPhase;
    DeployGate public deployGate;
    uint256 public validatedContracts;
    uint256 public executedContracts;
    bytes32[] private queuedSalts;
    bytes32[] private queuedInitCodeHashes;

    /// @dev Same as `_init`, but points every `submit` at the DeployGate, which becomes the salt
    ///      guardian: addresses derive from it rather than from whoever runs the script, which is what keeps
    ///      them equal across chains and lets the two phases be signed by different accounts.
    /// @param gate Gate to deploy through. Its address is what every gated address derives from, and
    ///        DeployGateDeployer is what brings it up, so this is all that is needed to reach a deployment.
    function _initGated(string memory suffix_, address deployer_, DeployPhase phase, DeployGate gate) internal {
        _init(suffix_);

        deployer = deployer_;

        require(address(gate).code.length > 0, "DeployGate is missing: run DeployGateDeployer first");

        deployGate = gate;
        deployPhase = phase;

        if (phase == DeployPhase.Validate) {
            console.log("Commitment for gate %s", vm.toString(address(gate)));
            console.log(string.concat(_pad("contract-version", 26), _pad("address", 44), "initCodeHash"));
        }

        // Starts over, discarding the state of a previous initialization
        validatedContracts = 0;
        executedContracts = 0;
        delete queuedSalts;
        delete queuedInitCodeHashes;
    }

    /// @notice Submits one contract to the DeployGate: committed while validating, deployed while executing.
    ///         Use this instead of `create3`, which deploys directly and bypasses the gate.
    /// @dev    The gate is what calls CreateX, so the addresses derive from it rather than from whoever runs
    ///         the script. That is what keeps them equal across chains, and lets the two phases be signed by
    ///         different accounts.
    ///
    ///         Validating deploys the contract locally, at the very address the executor will use, and the
    ///         caller rolls that back afterwards, so nothing of it reaches the chain. The commitment does not
    ///         need it — it is salts and init code hashes, both known without deploying anything — but it is
    ///         what the phase proves before the admin signs: that every address is still free, since CreateX
    ///         reverts on a taken one, and that every constructor runs, which is the whole wiring, the action
    ///         batchers doing it from theirs. Skipping it would leave both to fail after the signature.
    ///
    ///         It is also why re-validating over a partly executed deployment reverts, which costs nothing:
    ///         the gate deploys through CreateX too, so those addresses are just as taken for the executor.
    ///         `--resume` is what picks such a run back up.
    function submit(string memory contractName, string memory version, bytes memory initCode)
        public
        returns (address target)
    {
        return _submit(contractName, version, reportedSalt(contractName, version, address(deployGate)), initCode);
    }

    /// @notice Same as `submit`, for a contract the deployment does not report. The action batchers wire the
    ///         protocol from their constructors and deny themselves once they are done, so nothing ever reads
    ///         one back: keeping them out of the manifest keeps `env/<network>.json` to the contracts that are
    ///         still part of the protocol, and keeps verification from chasing addresses nobody needs.
    function submitUnreported(string memory contractName, string memory version, bytes memory initCode)
        public
        returns (address target)
    {
        return _submit(contractName, version, unreportedSalt(contractName, version, address(deployGate)), initCode);
    }

    /// @dev Deploying directly bypasses the gate, and lands at an address derived from the sender rather than
    ///      from the gate, so a gated script has no business reaching for it. Closed off because it would
    ///      otherwise read almost exactly like `submit`.
    function create3(string memory, string memory, bytes memory) internal pure override returns (address) {
        revert("Use submit() to deploy through the DeployGate");
    }

    function _submit(string memory contractName, string memory version, bytes32 salt, bytes memory initCode)
        private
        returns (address target)
    {
        target = computeCreate3Address(salt, address(deployGate));

        if (deployPhase == DeployPhase.Validate) {
            // Impersonating the gate is what lets CreateX put it at the canonical address
            vm.prank(address(deployGate));
            address local = CreateX.deployCreate3(salt, initCode);
            require(local == target, "Local deployment landed somewhere else");

            queuedSalts.push(salt);
            queuedInitCodeHashes.push(keccak256(initCode));

            // Printed as it is queued, not from the commitment, because console output is not state: it
            // survives the rollback that discards the walk, which is what leaves the phase reporting nothing
            console.log(
                string.concat(
                    _pad(string.concat(contractName, "-", version), 26),
                    vm.toString(target),
                    "  ",
                    vm.toString(keccak256(initCode))
                )
            );
            return target;
        }

        // Aborts the run before anything is broadcast when an init code changed since it was validated, or
        // when this contract is not the one the commitment expects next. Reports the address, which the
        // DeployGate itself cannot name
        if (deployGate.validated(salt) != deployGate.commitment(keccak256(initCode), executedContracts)) {
            console.log("Not validated, or out of order at position %s: %s", executedContracts, target);
            revert("Deployment does not match what was validated, validate again");
        }

        require(deployGate.deploy(salt, initCode) == target, "Deployment landed somewhere else");
        executedContracts++;
    }

    /// @dev Left-pads to a fixed width, so the commitment reads as a table and diffs line by line
    function _pad(string memory value, uint256 width) private pure returns (string memory) {
        bytes memory raw = bytes(value);
        if (raw.length >= width) return string.concat(value, " ");

        bytes memory padded = new bytes(width);
        for (uint256 i; i < width; i++) {
            padded[i] = i < raw.length ? raw[i] : bytes1(" ");
        }
        return string(padded);
    }

    /// @dev Copies the queue out of storage, so that it survives the caller rolling the local deployments
    ///      back: memory is not state.
    function _queuedCommitment() internal view returns (bytes32[] memory salts, bytes32[] memory initCodeHashes) {
        uint256 queued = queuedSalts.length;

        salts = new bytes32[](queued);
        initCodeHashes = new bytes32[](queued);

        for (uint256 i; i < queued; i++) {
            salts[i] = queuedSalts[i];
            initCodeHashes[i] = queuedInitCodeHashes[i];
        }
    }

    /// @dev Commits the whole deployment. Deliberately a single transaction, whatever the number of contracts,
    ///      since this is the one the admin has to sign.
    function _commit(bytes32[] memory salts, bytes32[] memory initCodeHashes) internal {
        deployGate.validate(salts, initCodeHashes);
        validatedContracts = salts.length;

        // One value to compare against a second, independent validate run, which needs no --broadcast: the
        // table above says which row differs when these do
        console.log("Validated %s contracts in 1 transaction", validatedContracts);
        console.log("Commitment digest %s", vm.toString(keccak256(abi.encode(salts, initCodeHashes))));
    }
}

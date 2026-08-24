// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {IDeployGate} from "../utils/gate/IDeployGate.sol";
import {DEPLOY_GATE_ADDRESS} from "../utils/gate/DeployGate.d.sol";
import {DeployGateScript} from "../utils/gate/DeployGateScript.sol";

/// @dev How a gated deployment is signed. The gate both phases need is brought up by the validate phase.
enum DeployPhase {
    // Commit what may be deployed and who may deploy it: the single transaction the admin signs
    Validate,
    // Deploy what has been committed, one transaction per contract
    Execute
}

/// @notice Deploys through a DeployGate instead of directly: an admin commits what may be deployed, in a
///         single transaction, and the executor it named then deploys it.
contract GatedDeployer is BaseDeployer, DeployGateScript {
    /// @dev The gate lets a validator hold several commitments at once. This deployment wants one, so it
    ///      pins an id and committing again always replaces what came before. Reaches no address.
    bytes32 internal constant DEFAULT_COMMITMENT_ID = bytes32(uint256(1));

    /// @dev Account signing the run. Not the one addresses derive from, which is the gate and the validator
    address public deployer;
    address public validator;

    /// @dev Whether a script is behind the run, rather than a test. It is what tells the two apart where
    ///      they should differ: a test drives the phases in-process, from a validator that stands for nobody
    ///      and prints its table once per fixture, so it neither reports nor proposes.
    bool internal scripting;

    /// @dev Whether the call the phase ends in is proposed to the validator's Safe rather than broadcast,
    ///      which follows from the validator itself: see `proposes`. Such a run broadcasts nothing at all,
    ///      because the proposal is posted over ffi the moment it is signed while a broadcast is deferred to
    ///      the end of the run, so a run doing both would post the proposal and then fail to send.
    bool internal proposing;

    DeployPhase internal deployPhase;
    IDeployGate public deployGate;
    uint256 public validatedContracts;
    uint256 public executedContracts;
    address[] private executors;
    bytes32[] private queuedSalts;
    bytes32[] private queuedInitCodeHashes;

    /// @dev Same as `_init`, but points every `submit` at the DeployGate: addresses derive from the gate and
    ///      the validator rather than from whoever runs the script, which is what keeps them equal across
    ///      chains and lets the two phases be signed by different accounts.
    /// @param validator_ Account whose namespace in the gate the deployment lives in. Addresses derive from
    ///        it alongside the salt, so it has to be the same account on every chain. The validate phase is
    ///        signed by it or by one of its delegates, and the execute phase needs none of its key
    /// @param executors_ Accounts the validate phase names as allowed to run the execute phase. They need no
    ///        privilege anywhere else, and none has to be the validator. Part of the commitment, so
    ///        replacing one means committing again
    function _initGated(
        string memory suffix_,
        address deployer_,
        DeployPhase phase,
        address validator_,
        address[] memory executors_
    ) internal {
        _init(suffix_);

        deployer = deployer_;

        require(validator_ != address(0), "A validator is required to derive addresses");

        deployGate = IDeployGate(DEPLOY_GATE_ADDRESS);
        validator = validator_;
        deployPhase = phase;

        scripting = vm.isContext(VmSafe.ForgeContext.ScriptGroup);
        proposing = scripting && phase == DeployPhase.Validate && proposes(validator_);

        // A proposing run brings no gate up itself — the deployment rides in its proposal — so the chain
        // stays readable for `_commitToGate` to build that proposal from; the walk gets a simulated gate
        // inside its rollback instead. Every other run wants one here: under a broadcast a missing gate is
        // deployed for real, as the transaction before the commitment's own
        if (!proposing) setUpDeployGate();

        // Fails a wrong sender at once rather than at the very end of the run, where the gate — or the Safe
        // transaction service, after the Ledger has already signed — would reject it anyway. One staticcall
        // against the registry that enforces it for real, so this can never disagree with it: who may send
        // the phase is decided there, and here it is only reported early
        if (scripting && phase == DeployPhase.Validate) {
            require(
                proposing
                    ? ISafe(validator_).isOwner(msg.sender)
                    : msg.sender == validator_ || deployGate.isDelegate(validator_, msg.sender),
                "Not the validator, one of its delegates, nor an owner of its Safe: pass a --sender the namespace answers to"
            );
        }

        if (phase == DeployPhase.Validate && scripting) {
            console.log("Validator %s", vm.toString(validator_));
            console.log(string.concat(_pad("contract-version", 26), _pad("address", 44), "initCodeHash"));
        }

        // Starts over, discarding the state of a previous initialization
        validatedContracts = 0;
        executedContracts = 0;
        executors = executors_;
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
        return _submit(
            contractName,
            version,
            _gatedSalt(contractName, version),
            reportedGatedAddress(contractName, version),
            initCode
        );
    }

    /// @notice Same as `submit`, for a contract the deployment does not report. The action batchers wire the
    ///         protocol from their constructors and deny themselves once they are done, so nothing ever reads
    ///         one back: keeping them out of the manifest keeps `env/<environment>/<network>.json` to the contracts that are
    ///         still part of the protocol, and keeps verification from chasing addresses nobody needs.
    function submitUnreported(string memory contractName, string memory version, bytes memory initCode)
        public
        returns (address target)
    {
        return _submit(
            contractName, version, _gatedSalt(contractName, version), gatedAddress(contractName, version), initCode
        );
    }

    /// @notice The address a contract is going to occupy, without deploying or reporting anything. Asking for
    ///         it is how the constructors that wire their dependencies reach the ones not yet deployed.
    function gatedAddress(string memory contractName, string memory version) public returns (address target) {
        target = deployGate.addressOf(validator, _gatedSalt(contractName, version));

        vm.label(target, string.concat(contractName, "-", version, "-", suffix));
    }

    /// @notice Same, for a contract the deployment reports, which is what puts it in `env/<environment>/<network>.json`.
    function reportedGatedAddress(string memory contractName, string memory version) public returns (address target) {
        target = gatedAddress(contractName, version);

        register(contractName, target, version);
    }

    /// @dev Deploying directly bypasses the gate, and lands at an address derived from the sender rather than
    ///      from the gate, so a gated script has no business reaching for it. Closed off because it would
    ///      otherwise read almost exactly like `submit`.
    function create3(string memory, string memory, bytes memory) internal pure override returns (address) {
        revert("Use submit() to deploy through the DeployGate");
    }

    /// @dev Salt a gated contract is deployed under. Any 32 bytes will do: the gate is what turns this into a
    ///      CreateX salt, folding in its own address and the validator.
    function _gatedSalt(string memory contractName, string memory version) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(contractName, _versionHash(version)));
    }

    function _submit(
        string memory contractName,
        string memory version,
        bytes32 salt,
        address target,
        bytes memory initCode
    ) private returns (address) {
        if (deployPhase == DeployPhase.Validate) {
            // Read before the prank, which only reaches the very next call
            bytes32 createXSalt = deployGate.createXSalt(validator, salt);

            // Impersonating the gate is what lets CreateX put it at the canonical address
            vm.prank(address(deployGate));
            address local = CreateX.deployCreate3(createXSalt, initCode);
            require(local == target, "Local deployment landed somewhere else");

            queuedSalts.push(salt);
            queuedInitCodeHashes.push(keccak256(initCode));

            // Printed as it is queued, not from the commitment, because console output is not state: it
            // survives the rollback that discards the walk, which is what leaves the phase reporting nothing
            if (scripting) {
                console.log(
                    string.concat(
                        _pad(string.concat(contractName, "-", version), 26),
                        vm.toString(target),
                        "  ",
                        vm.toString(keccak256(initCode))
                    )
                );
            }
            return target;
        }

        // Aborts the run before anything is broadcast when an init code changed since it was validated, or
        // when this contract is not the one the commitment expects next. Asks the gate where the commitment
        // stands rather than counting along with it, so that a run picking up a half-deployed commitment
        // reads the same position the gate is about to enforce. Reports the address, which the DeployGate
        // itself cannot name
        uint256 position = deployGate.deployed(validator, DEFAULT_COMMITMENT_ID);
        if (
            deployGate.validated(validator, DEFAULT_COMMITMENT_ID, salt)
                != deployGate.commitment(keccak256(initCode), position)
        ) {
            console.log("Not validated, or out of order at position %s: %s", position, target);
            revert("Deployment does not match what was validated, validate again");
        }

        require(
            deployGate.deploy(validator, DEFAULT_COMMITMENT_ID, salt, initCode) == target,
            "Deployment landed somewhere else"
        );
        executedContracts++;

        return target;
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

    /// @notice Drops what is committed under this deployment's id, so that none of it stays deployable.
    ///         Runs after `_initGated`, exactly as `_commit` does: revoking *is* committing, with nothing in
    ///         it, so it takes the same route to the gate as a commitment does.
    /// @dev    Deliberately reaches the gate without the walk the phases run: what makes a commitment worth
    ///         revoking is usually that its addresses are wrong or half taken, and a walk over a taken
    ///         address reverts inside CreateX before it could revoke anything
    function _revokeCommitment() internal {
        _commitToGate(new bytes32[](0), new bytes32[](0), new address[](0));
    }

    /// @notice Whether a validator is reached by proposing to it rather than by broadcasting from it. A
    ///         contract is taken to be a Safe: it cannot sign a forge broadcast, so there is nothing else it
    ///         could be here, and a key is the only thing that can. A Safe that named the signing key as its
    ///         delegate is not proposed to either — the delegate broadcasts to the gate directly, which is
    ///         what delegation is for.
    /// @dev    Read from the validator and the sender rather than passed in, so that no run can pick the
    ///         wrong one: the broadcast path cannot sign for a Safe, and the proposing path has no Safe to
    ///         post to. A chain without its gate holds no delegates, so there the Safe is always proposed
    ///         to, carrying the gate up itself.
    ///
    ///         Code starting 0xef is the one exception to code meaning a Safe: EIP-3541 keeps it
    ///         undeployable, so it can only be an EIP-7702 delegation, and under a delegation there is still
    ///         a key that signs its own broadcast
    function proposes(address validator_) public view returns (bool) {
        if (isDeployGateDeployed() && IDeployGate(DEPLOY_GATE_ADDRESS).isDelegate(validator_, msg.sender)) {
            return false;
        }

        bytes memory code = validator_.code;
        return code.length > 0 && code[0] != 0xef;
    }

    /// @dev The one call a validator ever makes, and the only place a phase reaches the gate to change
    ///      anything. A key signs it as a transaction; a Safe is handed the same call as a proposal its
    ///      owners sign afterwards, through `proposeGateCall`, which is also what brings the gate itself up
    ///      on a chain that has none — nothing else in a proposing run is broadcast
    function _commitToGate(bytes32[] memory salts, bytes32[] memory initCodeHashes, address[] memory executors_)
        internal
    {
        if (!proposing) {
            deployGate.validate(validator, DEFAULT_COMMITMENT_ID, salts, initCodeHashes, executors_);
            return;
        }

        proposeGateCall(
            validator,
            abi.encodeCall(IDeployGate.validate, (validator, DEFAULT_COMMITMENT_ID, salts, initCodeHashes, executors_))
        );
    }

    /// @dev Commits the whole deployment. Deliberately a single transaction, whatever the number of contracts,
    ///      since this is the one the admin has to sign.
    function _commit(bytes32[] memory salts, bytes32[] memory initCodeHashes) internal {
        _commitToGate(salts, initCodeHashes, executors);
        validatedContracts = salts.length;

        // One value to compare against a second, independent validate run, which needs no --broadcast: the
        // table above says which row differs when these do
        if (!scripting) return;

        console.log("Validated %s contracts in 1 transaction", validatedContracts);
        console.log("Commitment digest %s", vm.toString(keccak256(abi.encode(salts, initCodeHashes))));
    }
}

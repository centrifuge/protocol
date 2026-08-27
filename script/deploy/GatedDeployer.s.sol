// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer, AccountLib} from "./BaseDeployer.s.sol";

import {DEPLOY_GATE_ADDRESS} from "create3-gate/script/DeployGate.d.sol";

import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {IDeployGate} from "create3-gate/src/IDeployGate.sol";
import {GateProposalScript} from "../utils/GateProposal.s.sol";

/// @dev How a gated deployment is signed. The gate both phases need is brought up by the commit phase.
enum DeployPhase {
    // Commit what may be deployed and who may deploy it: the single transaction the admin signs
    Commit,
    // Deploy what has been committed, one transaction per contract
    Deploy
}

/// @notice Deploys through a DeployGate instead of directly: an admin commits what may be deployed, in a
///         single transaction, and the executor it named then deploys it.
contract GatedDeployer is BaseDeployer, GateProposalScript {
    using AccountLib for address;

    /// @dev The gate lets a namespace hold several commitments at once. This deployment wants one, so it
    ///      pins an id and committing again always replaces what came before. Reaches no address.
    bytes32 internal constant DEFAULT_COMMITMENT_ID = bytes32(uint256(1));

    /// @dev The account addresses derive from, alongside the gate and the salt. Not the one a phase acts as:
    ///      that is always `msg.sender` — committing, the namespace or a delegate it named; deploying, an
    ///      executor. A key acts by broadcasting; a Safe acts by having the call proposed to it, signed by
    ///      the owner on the Ledger. Nothing here cares which the caller arranged: a Ledger namespace
    ///      delegating to a Safe is as good as a Safe delegating to a key
    address public namespace;

    /// @dev Whether a script is behind the run, rather than a test. It is what tells the two apart where
    ///      they should differ: a test drives the phases in-process, from a namespace that stands for nobody
    ///      and prints its table once per fixture, so it neither reports nor proposes.
    bool internal scripting;

    /// @dev Whether the call the phase ends in is proposed to the sender rather than broadcast from it, which
    ///      is whether the sender is a Safe. Such a run broadcasts nothing at all, because the proposal is
    ///      posted over ffi the moment it is signed while a broadcast is deferred to the end of the run, so
    ///      a run doing both would post the proposal and then fail to send.
    bool internal proposing;

    DeployPhase internal deployPhase;
    IDeployGate public deployGate;
    uint256 public committedContracts;
    uint256 public deployedContracts;
    address[] private executors;
    bytes32[] private queuedSalts;
    bytes32[] private queuedInitCodeHashes;

    /// @dev Same as `_init`, but points every `submit` at the DeployGate: addresses derive from the gate and
    ///      the namespace rather than from whoever runs the script, which is what keeps them equal across
    ///      chains and lets the two phases be signed by different accounts.
    /// @param namespace_ Account whose namespace in the gate the deployment lives in. Addresses derive from
    ///        it alongside the salt, so it has to be the same account on every chain. The commit phase is
    ///        made in its name, by it or by one of its delegates — whichever `--sender` is, a key that
    ///        broadcasts or a Safe that is proposed to — and the deploy phase needs none of its key
    /// @param executors_ Accounts the commit phase names as allowed to run the deploy phase. They need no
    ///        privilege anywhere else, and none has to be the namespace. Part of the commitment, so
    ///        replacing one means committing again
    function _initGated(string memory deploymentId_, DeployPhase phase, address namespace_, address[] memory executors_)
        internal
    {
        _init(deploymentId_);

        require(namespace_ != address(0), "A namespace is required to derive addresses");

        deployGate = IDeployGate(DEPLOY_GATE_ADDRESS);
        namespace = namespace_;
        deployPhase = phase;

        scripting = vm.isContext(VmSafe.ForgeContext.ScriptGroup);
        proposing = scripting && phase == DeployPhase.Commit && msg.sender.isSafeAccount();

        // A proposing run brings no gate up itself — the deployment rides in its proposal — so the chain
        // stays readable for `_commitToGate` to build that proposal from; the walk gets a simulated gate
        // inside its rollback instead. Every other run wants one here: under a broadcast a missing gate is
        // deployed for real, as the transaction before the commitment's own
        if (!proposing) setUpDeployGate();

        // Fails a wrong sender at once rather than at the very end of the run, where the gate would reject
        // it anyway. One staticcall against the registry that enforces it for real, so this can never
        // disagree with it: who may commit is decided by the gate, and here it is only reported early. A
        // chain with no gate yet holds no delegates, so there only the namespace commits.
        //
        // `--sender` is the account the phase acts as, a Safe included: a proposing run broadcasts nothing,
        // so forge takes any address there, and the owner or proposer who signs is whoever holds the Ledger
        // — the Safe transaction service is what checks that account may propose, once it is posted.
        if (scripting && phase == DeployPhase.Commit) {
            require(
                msg.sender == namespace_ || (isDeployGateDeployed() && deployGate.isDelegate(namespace_, msg.sender)),
                "Not the namespace nor one of its delegates: pass a --sender the namespace answers to"
            );
        }

        if (phase == DeployPhase.Commit && scripting) {
            console.log("Namespace %s", vm.toString(namespace_));
            if (msg.sender != namespace_) console.log("Committing as %s", vm.toString(msg.sender));
            console.log(string.concat(_pad("contract-version", 26), _pad("address", 44), "initCodeHash"));
        }

        // Starts over, discarding the state of a previous initialization
        committedContracts = 0;
        deployedContracts = 0;
        executors = executors_;
        delete queuedSalts;
        delete queuedInitCodeHashes;
    }

    /// @notice Submits one contract to the DeployGate: committed in the commit phase, deployed in the deploy phase.
    ///         Use this instead of `create3`, which deploys directly and bypasses the gate.
    /// @dev    The gate is what deploys, so the addresses derive from it rather than from whoever runs
    ///         the script. That is what keeps them equal across chains, and lets the two phases be signed by
    ///         different accounts.
    ///
    ///         Committing deploys the contract locally, at the very address the executor will use, and the
    ///         caller rolls that back afterwards, so nothing of it reaches the chain. The commitment does not
    ///         need it — it is salts and init code hashes, both known without deploying anything — but it is
    ///         what the phase proves before the admin signs: that every address is still free, since the gate
    ///         reverts on a taken one, and that every constructor runs, which is the whole wiring, the action
    ///         batchers doing it from theirs. Skipping it would leave both to fail after the signature.
    ///
    ///         It is also why re-committing over a partly deployed deployment reverts, which costs nothing:
    ///         the walk deploys through the gate too, so those addresses are just as taken for the executor.
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
        target = deployGate.addressOf(namespace, _gatedSalt(contractName, version));

        vm.label(target, string.concat(contractName, "-", version, "-", deploymentId));
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

    /// @dev Salt a gated contract is deployed under. Any 32 bytes will do: the gate is what turns this into
    ///      the salt it deploys under, folding in the namespace, and its own address is the deployer.
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
        if (deployPhase == DeployPhase.Commit) {
            address local = _probeDeploy(salt, initCode);
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

        // Aborts the run before anything is broadcast when an init code changed since it was committed, or
        // when this contract is not the one the commitment expects next. Asks the gate where the commitment
        // stands rather than counting along with it, so that a run picking up a half-deployed commitment
        // reads the same position the gate is about to enforce. Reports the address, which the DeployGate
        // itself cannot name
        (,, uint64 position, uint64 deployableAt) = deployGate.commitments(namespace, DEFAULT_COMMITMENT_ID);
        if (block.timestamp < deployableAt) {
            console.log("Committed by a delegate, deployable at %s, now %s", deployableAt, block.timestamp);
            revert("The namespace's delay on delegate commitments has not passed yet");
        }
        if (
            deployGate.committed(namespace, DEFAULT_COMMITMENT_ID, salt)
                != deployGate.commitment(keccak256(initCode), position)
        ) {
            console.log("Not committed, or out of order at position %s: %s", position, target);
            revert("Deployment does not match what was committed, commit again");
        }

        require(
            deployGate.deploy(namespace, DEFAULT_COMMITMENT_ID, salt, initCode) == target,
            "Deployment landed somewhere else"
        );
        deployedContracts++;

        return target;
    }

    /// @dev Deploys one contract through the gate at the address the executor will use, for the walk that
    ///      proves a commit phase before it is signed. Commits it first, since the gate deploys nothing it
    ///      was not asked for, under an id of its own so the phase's commitment is left alone — and as the
    ///      namespace, which no chain ever sees: the walk runs unbroadcast and is rolled back whole.
    function _probeDeploy(bytes32 salt, bytes memory initCode) private returns (address) {
        bytes32 probeId = bytes32(uint256(DEFAULT_COMMITMENT_ID) + 1);
        bytes32[] memory salts = new bytes32[](1);
        bytes32[] memory initCodeHashes = new bytes32[](1);
        address[] memory probeExecutors = new address[](1);
        (salts[0], initCodeHashes[0], probeExecutors[0]) = (salt, keccak256(initCode), namespace);

        vm.startPrank(namespace);
        deployGate.commit(namespace, probeId, salts, initCodeHashes, probeExecutors);
        address local = deployGate.deploy(namespace, probeId, salt, initCode);
        vm.stopPrank();

        return local;
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
    ///         address reverts inside the gate before it could revoke anything
    function _revokeCommitment() internal {
        _commitToGate(new bytes32[](0), new bytes32[](0), new address[](0));
    }

    /// @dev The one call made in a namespace's name, and the only place a phase reaches the gate to change
    ///      anything. Made as the sender: a key signs it as a transaction; a Safe is handed the same call as
    ///      a proposal its owners sign afterwards, through `proposeGateCall`, which is also what brings the
    ///      gate itself up on a chain that has none — nothing else in a proposing run is broadcast
    function _commitToGate(bytes32[] memory salts, bytes32[] memory initCodeHashes, address[] memory executors_)
        internal
    {
        if (!proposing) {
            deployGate.commit(namespace, DEFAULT_COMMITMENT_ID, salts, initCodeHashes, executors_);
            return;
        }

        proposeGateCall(
            msg.sender,
            abi.encodeCall(IDeployGate.commit, (namespace, DEFAULT_COMMITMENT_ID, salts, initCodeHashes, executors_))
        );
    }

    /// @dev Commits the whole deployment. Deliberately a single transaction, whatever the number of contracts,
    ///      since this is the one the admin has to sign.
    function _commit(bytes32[] memory salts, bytes32[] memory initCodeHashes) internal {
        _commitToGate(salts, initCodeHashes, executors);
        committedContracts = salts.length;

        // One value to compare against a second, independent commit run, which needs no --broadcast: the
        // table above says which row differs when these do
        if (!scripting) return;

        console.log("Committed %s contracts in 1 transaction", committedContracts);
        console.log("Commitment digest %s", vm.toString(keccak256(abi.encode(salts, initCodeHashes))));
    }
}

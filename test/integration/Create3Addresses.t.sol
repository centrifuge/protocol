// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnsureDeployGate} from "../../script/utils/GateProposal.s.sol";
import {CREATEX_ADDRESS} from "../../script/utils/createx/CreateX.d.sol";
import {BaseDeployer, AccountLib} from "../../script/deploy/BaseDeployer.s.sol";
import {GatedDeployer, DeployPhase} from "../../script/deploy/GatedDeployer.s.sol";
import {
    DEPLOY_GATE_SALT,
    DEPLOY_GATE_ADDRESS,
    DEPLOY_GATE_BYTECODE,
    DEPLOY_GATE_EXTCODEHASH
} from "create3-gate/script/DeployGate.d.sol";

import "forge-std/Test.sol";

contract SimpleContract {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract Create3AddressesTest is Test, BaseDeployer {
    function setUp() public {
        _init("");
    }

    function testPreviewMatchesCreate3() public {
        address predicted = create3Address("testContract", "v3.1", address(this));
        address deployed = create3(
            reportedSalt("testContract", "v3.1", address(this)),
            abi.encodePacked(type(SimpleContract).creationCode, abi.encode(42))
        );

        assertEq(deployed, predicted, "CREATE3 address does not match preview");
        assertEq(SimpleContract(deployed).value(), 42);
    }

    function testPreviewMatchesCreate3WithDeploymentId() public {
        _init("rev2");

        address predicted = create3Address("testContract", "v3.1", address(this));
        address deployed = create3(
            reportedSalt("testContract", "v3.1", address(this)),
            abi.encodePacked(type(SimpleContract).creationCode, abi.encode(99))
        );

        assertEq(deployed, predicted, "CREATE3 address does not match preview with a deployment id");
        assertEq(SimpleContract(deployed).value(), 99);
    }

    function testDeploymentIdProducesDifferentAddress() public {
        address withoutId = create3Address("testContract", "v3.1", address(this));

        _init("rev2");
        address withId = create3Address("testContract", "v3.1", address(this));

        assertTrue(withoutId != withId, "A deployment id should produce a different address");
    }

    function testDifferentDeployersProduceDifferentAddresses() public {
        address addr1 = create3Address("testContract", "v3.1", address(this));
        address addr2 = create3Address("testContract", "v3.1", makeAddr("otherDeployer"));

        assertTrue(addr1 != addr2, "Different deployers should produce different addresses");
    }
}

/// @dev The gate as a deployment reaches it: an address, a salt and a codehash. What those are checked
///      against lives with the contract, in lib/create3-gate.
contract DeployGateAddressTest is Test, BaseDeployer {
    function setUp() public {
        _init("");
    }

    /// @dev The salt names no sender, so CreateX derives the address from the salt alone, whoever calls it.
    ///      address(0) is the single exception and only inside a prank: CreateX reads a salt as naming a
    ///      sender when its first 20 bytes equal `msg.sender`, which a zero salt does for that one caller. No
    ///      transaction is ever sent by address(0), so this assumes away a state the chain cannot reach —
    ///      and it is the only such caller, which a non-zero salt could not claim
    function testAnyoneCanDeployTheGate(address anyone) public {
        vm.assume(anyone != address(0));

        assertEq(DEPLOY_GATE_ADDRESS.code.length, 0, "nothing there yet");

        vm.prank(anyone);
        address deployed = CreateX.deployCreate2(DEPLOY_GATE_SALT, DEPLOY_GATE_BYTECODE);

        assertEq(deployed, DEPLOY_GATE_ADDRESS, "whoever deploys it, it lands in the same place");
        assertEq(deployed.codehash, DEPLOY_GATE_EXTCODEHASH, "and it is the gate");
    }

    /// @dev Which is the whole point: one gate, one address, everywhere. Nothing chain-specific reaches the
    ///      derivation, so a constant can stand for it
    function testGateAddressIsTheSameOnEveryChain() public {
        address here = CreateX.computeCreate2Address(
            keccak256(abi.encode(DEPLOY_GATE_SALT)), keccak256(DEPLOY_GATE_BYTECODE), CREATEX_ADDRESS
        );

        vm.chainId(block.chainid + 1);

        assertEq(
            CreateX.computeCreate2Address(
                keccak256(abi.encode(DEPLOY_GATE_SALT)), keccak256(DEPLOY_GATE_BYTECODE), CREATEX_ADDRESS
            ),
            here,
            "the chain id must not reach the gate's address"
        );
    }

    /// @dev A CREATE3 gate address would be code anyone could choose, and the gate's code is its whole
    ///      authority. Under CREATE2 the only contract that fits its address is the gate
    function testGateAddressCoversItsCode() public pure {
        address impostor = CreateX.computeCreate2Address(
            keccak256(abi.encode(DEPLOY_GATE_SALT)), keccak256(type(SimpleContract).creationCode), CREATEX_ADDRESS
        );

        assertTrue(impostor != DEPLOY_GATE_ADDRESS, "another contract must not reach the gate's address");
    }

    /// @dev Which is how a chain that derives addresses its own way is caught, rather than deployed onto
    function testImpostorIsRejected() public {
        address impostor = address(new SimpleContract(1));

        assertTrue(impostor.codehash != DEPLOY_GATE_EXTCODEHASH, "the wrong code");
        assertTrue(DEPLOY_GATE_ADDRESS.codehash != DEPLOY_GATE_EXTCODEHASH, "nor is an empty address the gate");

        vm.etch(DEPLOY_GATE_ADDRESS, impostor.code);
        assertTrue(DEPLOY_GATE_ADDRESS.codehash != DEPLOY_GATE_EXTCODEHASH, "nor the right address with wrong code");
    }

    /// @dev What makes CreateX take the salt as it is, rather than scoping it to a caller or a chain. A zero
    ///      guardian folds the chain id in only when the 21st byte asks for redeploy protection; held at
    ///      zero it falls through to the salt alone
    function testGateSaltIsUnscoped() public pure {
        assertEq(DEPLOY_GATE_SALT, bytes32(0));
        assertEq(DEPLOY_GATE_SALT[20], bytes1(0x0), "redeploy protection should stay off");
    }

    /// @dev The batch leg a Safe proposal carries in place of the gate's own deployment: it has to work
    ///      however late the proposal executes, so a gate landing first is stepped aside from rather than
    ///      reverted on — which a direct deployCreate2 in the batch would do, taking the gate call behind
    ///      it down too
    function testEnsureDeployGateDeploysAndStepsAside() public {
        assertEq(DEPLOY_GATE_ADDRESS.code.length, 0, "nothing there yet");

        // The way the proposal posts it: through CreateX, which has to accept a carrier with no functions
        address carrier = CreateX.deployCreate(type(EnsureDeployGate).creationCode);
        assertGt(carrier.code.length, 0, "CreateX must accept the carrier");
        assertEq(DEPLOY_GATE_ADDRESS.codehash, DEPLOY_GATE_EXTCODEHASH, "brings the gate up");

        new EnsureDeployGate();
        assertEq(DEPLOY_GATE_ADDRESS.codehash, DEPLOY_GATE_EXTCODEHASH, "and steps aside from one already there");
    }

    /// @dev What it cannot step aside from it rejects, so the gate call behind it never lands in foreign code
    function testEnsureDeployGateRejectsImpostor() public {
        address impostor = address(new SimpleContract(1));
        vm.etch(DEPLOY_GATE_ADDRESS, impostor.code);

        vm.expectRevert(bytes("Not the DeployGate"));
        new EnsureDeployGate();
    }
}

contract Create3GatedAddressesTest is Test, GatedDeployer {
    using AccountLib for address;

    function setUp() public {
        // Nothing places the gate first: initialising the deployment is what brings it up
        _initGated("", DeployPhase.Commit, address(this), _executors());
    }

    function _executors() internal view returns (address[] memory executors) {
        executors = new address[](1);
        executors[0] = address(this);
    }

    function _preview(string memory name, string memory version) internal returns (address) {
        return gatedAddress(name, version);
    }

    /// @dev `vm.expectRevert` only sees external calls
    function initGated(string memory deploymentId_, DeployPhase phase, address namespace_) external {
        _initGated(deploymentId_, phase, namespace_, _executors());
    }

    /// @dev How the acting account is reached follows from what it is: a key is broadcast from, a contract
    ///      is a Safe and is proposed to, and code under EIP-7702 is still a key
    function testASafeAccountIsAContractButNotADelegation() public {
        address key = makeAddr("key");
        address safe = makeAddr("safe");
        address delegated = makeAddr("delegated");
        vm.etch(safe, hex"6001");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", key));

        assertFalse(key.isSafeAccount(), "a key broadcasts");
        assertTrue(safe.isSafeAccount(), "a contract is proposed to");
        assertFalse(delegated.isSafeAccount(), "an EIP-7702 delegation still has a key behind it");
    }

    /// @dev `vm.expectRevert` only sees external calls
    function deployDirectly() external pure {
        create3("testContract", "v3.1", abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1)));
    }

    /// @dev A gated script must not reach for the inherited helper: it would bypass the gate entirely and land
    ///      at an address derived from the sender, while reading almost exactly like `submit`
    function testDeployingDirectlyIsClosedOff() public {
        vm.expectRevert("Use submit() to deploy through the DeployGate");
        this.deployDirectly();
    }

    /// @dev What the commit phase does: walk it locally, carry the commitment out in memory, roll back
    function queueAndCommit(uint256 value) external returns (address target) {
        uint256 snapshot = vm.snapshotState();

        target = submit("testContract", "v3.1", abi.encodePacked(type(SimpleContract).creationCode, abi.encode(value)));
        (bytes32[] memory salts, bytes32[] memory initCodeHashes) = _queuedCommitment();

        vm.revertToState(snapshot);

        _commit(salts, initCodeHashes);
    }

    function deployIt(uint256 value) external returns (address) {
        _initGated("", DeployPhase.Deploy, address(this), _executors());
        return submit("testContract", "v3.1", abi.encodePacked(type(SimpleContract).creationCode, abi.encode(value)));
    }

    // The DeployGate address

    /// @dev Addresses follow the gate, not the signer, which is what keeps them equal across chains
    function testAddressesDoNotFollowTheSigner() public {
        address throughGate = _preview("testContract", "v3.1");
        address ungated = create3Address("testContract", "v3.1", address(this));

        assertTrue(ungated != throughGate, "deploying directly would land somewhere else entirely");
        assertEq(namespace, address(this), "the namespace is what addresses derive from, alongside the gate");
    }

    /// @dev The whole point of the scheme: nothing chain-specific reaches a gated address, so the same
    ///      contract at the same version lands in the same place on every chain. A chain id folded into the
    ///      salt anywhere between here and CreateX would show up as a different preview
    function testGatedAddressesAreTheSameOnEveryChain() public {
        address here = _preview("testContract", "v3.1");

        vm.chainId(block.chainid + 1);
        _initGated("", DeployPhase.Commit, address(this), _executors());

        assertEq(_preview("testContract", "v3.1"), here, "the chain id must not reach a gated address");
    }

    /// @dev One gate serves every deployment on a chain, so the namespace is what keeps two of them apart
    function testAddressesFollowTheNamespace() public {
        address mine = _preview("testContract", "v3.1");

        _initGated("", DeployPhase.Commit, makeAddr("anotherNamespace"), _executors());

        assertTrue(_preview("testContract", "v3.1") != mine, "another namespace, another address");
    }

    /// @dev A chain with no gate gets one, so a deployment needs nothing run before it. `setUp` is the
    ///      proof: it initialises against a fresh chain that has never seen a gate
    function testGatingBringsUpTheGate() public view {
        assertEq(DEPLOY_GATE_ADDRESS.codehash, DEPLOY_GATE_EXTCODEHASH, "initialising brought the gate up");
    }

    /// @dev What a chain deriving addresses its own way looks like: the gate is not where it should be
    function testGatingOntoForeignCodeFails() public {
        vm.etch(DEPLOY_GATE_ADDRESS, address(new SimpleContract(1)).code);

        vm.expectRevert("Not the DeployGate: unexpected code at that address");
        this.initGated("", DeployPhase.Commit, address(this));
    }

    function testGatingWithoutANamespaceFails() public {
        vm.expectRevert("A namespace is required to derive addresses");
        this.initGated("", DeployPhase.Commit, address(0));
    }

    function testDeploymentIdIsolatesGatedDeployments() public {
        address withoutId = _preview("testContract", "v3.1");

        _initGated("rev2", DeployPhase.Commit, address(this), _executors());

        assertTrue(_preview("testContract", "v3.1") != withoutId, "The deployment id should move the addresses");
    }

    // Commit, then deploy

    function testCommitPhaseDeploysNothing() public {
        address predicted = _preview("testContract", "v3.1");
        address queued = this.queueAndCommit(42);

        assertEq(queued, predicted, "Queued address does not match preview");
        assertEq(predicted.code.length, 0, "committing should deploy nothing");
        assertEq(committedContracts, 1);
        assertTrue(deployGate.committed(namespace, DEFAULT_COMMITMENT_ID, _gatedSalt("testContract", "v3.1")) != 0);
        assertTrue(
            deployGate.isExecutor(namespace, DEFAULT_COMMITMENT_ID, address(this)), "committing names the executors too"
        );
    }

    function testDeployPhaseDeploysWhatWasCommitted() public {
        address predicted = this.queueAndCommit(42);

        address deployed = this.deployIt(42);

        assertEq(deployed, predicted, "the executor cannot move the address");
        assertEq(SimpleContract(predicted).value(), 42);
        assertEq(deployedContracts, 1);
        assertEq(
            deployGate.committed(namespace, DEFAULT_COMMITMENT_ID, _gatedSalt("testContract", "v3.1")),
            0,
            "commitment consumed"
        );
    }

    /// @dev Caught in the script, before anything is broadcast
    function testDeployPhaseRejectsAChangedInitCode() public {
        this.queueAndCommit(42);

        vm.expectRevert("Deployment does not match what was committed, commit again");
        this.deployIt(43);
    }

    /// @dev Nothing is ever deployed over, and nothing already deployed is reused. Rerunning a commitment
    ///      that went through hits its spent commitment, so recovering a partial deploy means moving the
    ///      deployment id or the version: an earlier release's contracts are warded by its batchers, which denied
    ///      themselves, so a later run could never wire them.
    function testDeployPhaseRefusesToRedeploy() public {
        address predicted = this.queueAndCommit(1);
        this.deployIt(1);

        vm.expectRevert("Deployment does not match what was committed, commit again");
        this.deployIt(1);

        assertEq(SimpleContract(predicted).value(), 1, "what was deployed should stay untouched");
    }
}

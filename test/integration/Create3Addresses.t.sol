// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployGate} from "../../src/deployment/misc/DeployGate.sol";

import {ICreateX} from "../../script/utils/createx/ICreateX.sol";
import {BaseDeployer} from "../../script/deploy/BaseDeployer.s.sol";
import {GatedDeployer, DeployPhase} from "../../script/deploy/GatedDeployer.s.sol";

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

    function testPreviewMatchesCreate3WithSuffix() public {
        _init("rev2");

        address predicted = create3Address("testContract", "v3.1", address(this));
        address deployed = create3(
            reportedSalt("testContract", "v3.1", address(this)),
            abi.encodePacked(type(SimpleContract).creationCode, abi.encode(99))
        );

        assertEq(deployed, predicted, "CREATE3 address does not match preview with suffix");
        assertEq(SimpleContract(deployed).value(), 99);
    }

    function testSuffixProducesDifferentAddress() public {
        address withoutSuffix = create3Address("testContract", "v3.1", address(this));

        _init("rev2");
        address withSuffix = create3Address("testContract", "v3.1", address(this));

        assertTrue(withoutSuffix != withSuffix, "Suffix should produce a different address");
    }

    function testDifferentDeployersProduceDifferentAddresses() public {
        address addr1 = create3Address("testContract", "v3.1", address(this));
        address addr2 = create3Address("testContract", "v3.1", makeAddr("otherDeployer"));

        assertTrue(addr1 != addr2, "Different deployers should produce different addresses");
    }
}

contract Create3GatedAddressesTest is Test, GatedDeployer {
    DeployGate internal gate;

    function setUp() public {
        address[] memory executors = new address[](1);
        executors[0] = address(this);

        // What DeployGateDeployer does, in its own isolated run
        gate = new DeployGate(address(this), makeAddr("governance"), executors);

        _initGated("", address(this), DeployPhase.Validate, gate);
    }

    function _preview(string memory name, string memory version) internal returns (address) {
        return create3Address(name, version, address(deployGate));
    }

    /// @dev `vm.expectRevert` only sees external calls
    function initGated(string memory suffix_, address deployer_, DeployPhase phase, DeployGate gate_) external {
        _initGated(suffix_, deployer_, phase, gate_);
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

    /// @dev What the validate phase does: walk it locally, carry the commitment out in memory, roll back
    function queueAndValidate(uint256 value) external returns (address target) {
        uint256 snapshot = vm.snapshotState();

        target = submit("testContract", "v3.1", abi.encodePacked(type(SimpleContract).creationCode, abi.encode(value)));
        (bytes32[] memory salts, bytes32[] memory initCodeHashes) = _queuedCommitment();

        vm.revertToState(snapshot);

        _commit(salts, initCodeHashes);
    }

    function execute(uint256 value) external returns (address) {
        _initGated("", address(this), DeployPhase.Execute, gate);
        return submit("testContract", "v3.1", abi.encodePacked(type(SimpleContract).creationCode, abi.encode(value)));
    }

    // The DeployGate address

    function testDeployGateIsTheSaltGuardian() public view {
        assertEq(
            address(bytes20(_makeSalt("testContract", "v3.1", address(deployGate)))),
            address(deployGate),
            "DeployGate should guard the salts"
        );
        assertEq(deployer, address(this), "Deployer should stay the signer");
        assertEq(deployGate.wards(address(this)), 1, "deploying it should make you its admin");
        assertTrue(deployGate.isExecutor(address(this)), "the gate is seeded with this contract as executor");
    }

    /// @dev Addresses follow the gate, which is what keeps them equal across chains and independent of the
    ///      account running the script
    function testAddressesFollowTheGate() public {
        address throughGate = _preview("testContract", "v3.1");

        address[] memory executors = new address[](1);
        executors[0] = address(this);

        _initGated(
            "", address(this), DeployPhase.Validate, new DeployGate(address(this), makeAddr("governance"), executors)
        );
        assertTrue(_preview("testContract", "v3.1") != throughGate, "another gate, another address");

        // The signer deploying directly, instead of through a gate, moves them as well
        address ungated = create3Address("testContract", "v3.1", address(this));
        assertTrue(ungated != throughGate, "ungated moves them too");
    }

    function testGatingWithoutAGateFails() public {
        vm.expectRevert("DeployGate is missing: run DeployGateDeployer first");
        this.initGated("", address(this), DeployPhase.Validate, DeployGate(makeAddr("nothing")));
    }

    function testSuffixIsolatesGatedDeployments() public {
        address withoutSuffix = _preview("testContract", "v3.1");

        _initGated("rev2", address(this), DeployPhase.Validate, gate);

        assertTrue(_preview("testContract", "v3.1") != withoutSuffix, "Suffix should move the addresses");
    }

    // Validate, then execute

    function testValidatePhaseDeploysNothing() public {
        address predicted = _preview("testContract", "v3.1");
        address queued = this.queueAndValidate(42);

        assertEq(queued, predicted, "Queued address does not match preview");
        assertEq(predicted.code.length, 0, "validating should deploy nothing");
        assertEq(validatedContracts, 1);
        assertTrue(deployGate.validated(_makeSalt("testContract", "v3.1", address(deployGate))) != 0);
        assertTrue(deployGate.isExecutor(address(this)), "the executor may deploy what was validated");
    }

    function testExecutePhaseDeploysWhatWasValidated() public {
        address predicted = this.queueAndValidate(42);

        address deployed = this.execute(42);

        assertEq(deployed, predicted, "the executor cannot move the address");
        assertEq(SimpleContract(predicted).value(), 42);
        assertEq(executedContracts, 1);
        assertEq(
            deployGate.validated(_makeSalt("testContract", "v3.1", address(deployGate))),
            0,
            "validation should be consumed"
        );
    }

    /// @dev Caught in the script, before anything is broadcast
    function testExecutePhaseRejectsAChangedInitCode() public {
        this.queueAndValidate(42);

        vm.expectRevert("Deployment does not match what was validated, validate again");
        this.execute(43);
    }

    /// @dev Nothing is ever deployed over, and nothing already deployed is reused. Rerunning a commitment
    ///      that went through hits its spent validation, so recovering a partial execute means moving the
    ///      suffix or the version: an earlier release's contracts are warded by its batchers, which denied
    ///      themselves, so a later run could never wire them.
    function testExecutePhaseRefusesToRedeploy() public {
        address predicted = this.queueAndValidate(1);
        this.execute(1);

        vm.expectRevert("Deployment does not match what was validated, validate again");
        this.execute(1);

        assertEq(SimpleContract(predicted).value(), 1, "what was deployed should stay untouched");
    }

    /// @dev And when the validation is still live, because the address was taken by something else, CreateX
    ///      is the one that refuses
    function testExecutePhaseRefusesAnAddressTakenByAnotherDeployment() public {
        address predicted = this.queueAndValidate(1);

        vm.prank(address(gate));
        CreateX.deployCreate3(
            _makeSalt("testContract", "v3.1", address(gate)),
            abi.encodePacked(type(SimpleContract).creationCode, abi.encode(7))
        );
        assertGt(predicted.code.length, 0, "the address should be taken");

        vm.expectRevert(abi.encodeWithSelector(ICreateX.FailedContractCreation.selector, address(CreateX)));
        this.execute(1);
    }
}

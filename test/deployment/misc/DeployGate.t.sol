// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {DeployGate} from "../../../src/deployment/misc/DeployGate.sol";
import {IDeployGate} from "../../../src/deployment/misc/interfaces/IDeployGate.sol";

import {ICreateX} from "../../../script/utils/ICreateX.sol";
import {CREATEX_ADDRESS} from "../../../script/utils/CreateX.d.sol";
import {CreateXScript} from "../../../script/utils/CreateXScript.sol";

import "forge-std/Test.sol";

contract Target {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract DeployGateTest is Test, CreateXScript {
    address immutable ADMIN = address(this);
    address immutable EXECUTOR = makeAddr("executor");
    address immutable ROOT = makeAddr("root");

    DeployGate deployGate;

    function setUp() public {
        setUpCreateXFactory();

        address[] memory executors = new address[](1);
        executors[0] = EXECUTOR;

        // The deployer is the first admin, Root is a ward alongside it, and the executor is neither
        deployGate = new DeployGate(ADMIN, ROOT, executors);
    }

    /// @dev Mimics the production salt: guardian address, zero redeploy protection flag, name hash
    function _salt(address guardian, uint88 name) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(bytes20(guardian), bytes1(0x0), bytes11(name)));
    }

    function _initCode(uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Target).creationCode, abi.encode(value));
    }

    function _pairs(uint256 length) internal view returns (bytes32[] memory salts, bytes[] memory initCodes) {
        salts = new bytes32[](length);
        initCodes = new bytes[](length);

        for (uint256 i; i < length; i++) {
            salts[i] = _salt(address(deployGate), uint88(i + 1));
            initCodes[i] = _initCode(i + 1);
        }
    }

    function _validate(bytes32[] memory salts, bytes[] memory initCodes) internal {
        bytes32[] memory initCodeHashes = new bytes32[](initCodes.length);
        for (uint256 i; i < initCodes.length; i++) {
            initCodeHashes[i] = keccak256(initCodes[i]);
        }

        vm.prank(ADMIN);
        deployGate.validate(salts, initCodeHashes);
    }

    function _deploy(bytes32[] memory salts, bytes[] memory initCodes) internal returns (address[] memory targets) {
        targets = new address[](salts.length);
        for (uint256 i; i < salts.length; i++) {
            vm.prank(EXECUTOR);
            targets[i] = deployGate.deploy(salts[i], initCodes[i]);
        }
    }

    // Administration

    function testAdmin() public view {
        assertEq(deployGate.wards(ADMIN), 1, "the deployer is the first admin");
        assertEq(deployGate.wards(ROOT), 1, "root governs the gate from the start");
        assertEq(deployGate.nonce(), 0, "nothing validated yet");
        assertTrue(deployGate.isExecutor(EXECUTOR), "the constructor seeds the executors");
    }

    /// @dev A zero would silently lose the account meant to be able to rotate the admin, leaving the gate
    ///      governed by nobody but its deployer
    function testConstructorRejectsZeroGovernance() public {
        vm.expectRevert(IDeployGate.NoGovernance.selector);
        new DeployGate(ADMIN, address(0), new address[](0));
    }

    /// @dev Which is what Root.relyContract does, so governance can rotate the admin without the current one
    function testRootCanNameAnotherAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(ROOT);
        deployGate.rely(newAdmin);
        deployGate.deny(ADMIN);
        vm.stopPrank();

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(initCodes[0]);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        deployGate.validate(salts, hashes);

        vm.prank(newAdmin);
        deployGate.validate(salts, hashes);
        assertEq(deployGate.validated(salts[0]), deployGate.commitment(hashes[0], 0));
    }

    /// @dev Handing it over moves no address, since a CREATE3 address ignores the init code
    function testHandOverTheAdminRole() public {
        address newAdmin = makeAddr("newAdmin");

        deployGate.rely(newAdmin);
        deployGate.deny(ADMIN);

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(initCodes[0]);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        deployGate.validate(salts, hashes);

        vm.prank(newAdmin);
        deployGate.validate(salts, hashes);
        assertEq(deployGate.validated(salts[0]), deployGate.commitment(hashes[0], 0));
    }

    // Validate

    function testValidate() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);

        _validate(salts, initCodes);

        assertEq(deployGate.validated(salts[0]), deployGate.commitment(keccak256(initCodes[0]), 0));
        assertEq(deployGate.validated(salts[1]), deployGate.commitment(keccak256(initCodes[1]), 1));
        assertTrue(deployGate.isExecutor(EXECUTOR), "the executor may deploy it");
        assertEq(deployGate.nonce(), 1, "the first commitment is the first nonce");
    }

    /// @dev A validation replaces the whole previous one, so a salt dropped from the set must not linger as an
    ///      approval nobody remembers giving: an executor could otherwise spend it to strand that address
    function testValidateAgainDropsWhatItDoesNotMention() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        // A corrected set, under salts of its own, leaving both of the above behind
        (bytes32[] memory corrected, bytes[] memory correctedInitCodes) = _pairs(2);
        corrected[0] = _salt(address(deployGate), 100);
        corrected[1] = _salt(address(deployGate), 101);
        _validate(corrected, correctedInitCodes);

        assertEq(deployGate.nonce(), 2, "validating again starts a nonce");
        assertEq(deployGate.validated(salts[0]), 0, "the dropped salts should be gone");
        assertEq(deployGate.validated(salts[1]), 0, "the dropped salts should be gone");

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(salts[0], initCodes[0]);

        // What the new nonce does commit to deploys as usual
        assertEq(Target(_deploy(corrected, correctedInitCodes)[0]).value(), 1);
    }

    /// @dev A repeated salt would leave one storage entry behind two Validate events, so an off-chain reader
    ///      rebuilding the commitment from the log would see a hash that was never enforceable. The deploy
    ///      script cannot produce one (its local walk deploys at the salt, so the second reverts at CreateX),
    ///      but `validate` is callable with any calldata, so it refuses rather than letting the last one win
    function testValidateRejectsDuplicateSalts() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        bytes32[] memory initCodeHashes = new bytes32[](2);
        initCodeHashes[0] = keccak256(initCodes[0]);
        initCodeHashes[1] = keccak256(initCodes[1]);
        salts[1] = salts[0];

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.DuplicateSalt.selector, salts[0]));
        deployGate.validate(salts, initCodeHashes);
    }

    /// @dev Which is how a commitment is revoked outright, without naming a replacement for it
    function testValidateNothingRevokesEverything() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.prank(ADMIN);
        deployGate.validate(new bytes32[](0), new bytes32[](0));

        assertEq(deployGate.validated(salts[0]), 0, "nothing should be left validated");

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(salts[0], initCodes[0]);
    }

    /// @dev Rotating a key leaves the commitment alone, so a compromised executor is dropped without having
    ///      to validate the deployment again
    function testUpdateExecutor() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        address other = makeAddr("otherExecutor");

        vm.startPrank(ADMIN);
        deployGate.updateExecutor(other, true);
        deployGate.updateExecutor(EXECUTOR, false);
        vm.stopPrank();

        assertTrue(deployGate.isExecutor(other), "the new executor may deploy");
        assertFalse(deployGate.isExecutor(EXECUTOR), "the revoked one may not");
        assertEq(
            deployGate.validated(salts[0]),
            deployGate.commitment(keccak256(initCodes[0]), 0),
            "the commitment is untouched"
        );

        vm.prank(EXECUTOR);
        vm.expectRevert(IDeployGate.NotExecutor.selector);
        deployGate.deploy(salts[0], initCodes[0]);

        vm.prank(other);
        assertEq(Target(deployGate.deploy(salts[0], initCodes[0])).value(), 1);
    }

    function testUpdateExecutorNotAuthorized(address nonAdmin) public {
        vm.assume(nonAdmin != ADMIN && nonAdmin != ROOT);

        vm.prank(nonAdmin);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        deployGate.updateExecutor(nonAdmin, true);
    }

    function testUpdateExecutorEmitsEvent() public {
        address other = makeAddr("otherExecutor");

        vm.expectEmit();
        emit IDeployGate.UpdateExecutor(other, true);

        vm.prank(ADMIN);
        deployGate.updateExecutor(other, true);
    }

    /// @dev Any of them may deploy any of the contracts, so the phase can be split between keys
    function testSeveralExecutors() public {
        address other = makeAddr("otherExecutor");

        vm.prank(ADMIN);
        deployGate.updateExecutor(other, true);

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        // Neither is confined to a subset of the commitment: they are interchangeable
        vm.prank(other);
        assertEq(Target(deployGate.deploy(salts[0], initCodes[0])).value(), 1);

        vm.prank(EXECUTOR);
        assertEq(Target(deployGate.deploy(salts[1], initCodes[1])).value(), 2);
    }

    function testValidateEmitsEvent() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        bytes32[] memory initCodeHashes = new bytes32[](2);
        for (uint256 i; i < 2; i++) {
            initCodeHashes[i] = keccak256(initCodes[i]);
        }

        // One per contract, so that the commitment can be read back from a single transaction
        vm.expectEmit();
        emit IDeployGate.Validate(salts[0], initCodeHashes[0]);
        vm.expectEmit();
        emit IDeployGate.Validate(salts[1], initCodeHashes[1]);

        vm.prank(ADMIN);
        deployGate.validate(salts, initCodeHashes);
    }

    function testValidateNotAuthorized(address nonAdmin) public {
        vm.assume(nonAdmin != ADMIN && nonAdmin != ROOT);

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        bytes32[] memory initCodeHashes = new bytes32[](1);
        initCodeHashes[0] = keccak256(initCodes[0]);

        vm.prank(nonAdmin);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        deployGate.validate(salts, initCodeHashes);
    }

    function testValidateLengthMismatch() public {
        (bytes32[] memory salts,) = _pairs(2);

        vm.prank(ADMIN);
        vm.expectRevert(IDeployGate.LengthMismatch.selector);
        deployGate.validate(salts, new bytes32[](1));
    }

    /// @dev How a mistake is corrected before executing
    function testValidateAgainReplacesTheInitCode() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        initCodes[0] = _initCode(99);
        _validate(salts, initCodes);

        assertEq(Target(_deploy(salts, initCodes)[0]).value(), 99);
    }

    // Execute

    /// @dev The executor cannot validate, and needs no other privilege: the validated set determines what
    ///      lands where
    function testDeploy() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(3);
        _validate(salts, initCodes);

        assertEq(deployGate.wards(EXECUTOR), 0, "the executor is not an admin");

        address[] memory targets = _deploy(salts, initCodes);

        assertEq(targets.length, 3);
        for (uint256 i; i < targets.length; i++) {
            assertEq(targets[i], computeCreate3Address(salts[i], address(deployGate)), "unexpected address");
            assertEq(Target(targets[i]).value(), i + 1);
        }
    }

    function testDeployEmitsEvent() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.expectEmit();
        emit IDeployGate.Deploy(salts[0], computeCreate3Address(salts[0], address(deployGate)));

        _deploy(salts, initCodes);
    }

    function testDeployNotExecutor(address nonExecutor) public {
        vm.assume(nonExecutor != EXECUTOR);

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.prank(nonExecutor);
        vm.expectRevert(IDeployGate.NotExecutor.selector);
        deployGate.deploy(salts[0], initCodes[0]);
    }

    function testDeployNotValidated() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);

        // Only the first one is validated, which is also what names the executor
        bytes32[] memory oneSalt = new bytes32[](1);
        bytes[] memory oneInitCode = new bytes[](1);
        oneSalt[0] = salts[0];
        oneInitCode[0] = initCodes[0];
        _validate(oneSalt, oneInitCode);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[1]));
        deployGate.deploy(salts[1], initCodes[1]);
    }

    /// @dev Validating commits to the init code, so an executor cannot substitute the bytecode
    function testDeployOtherInitCode() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        initCodes[0] = _initCode(666);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(salts[0], initCodes[0]);
    }

    /// @dev Validating commits to the salt as well, so an executor cannot deploy validated code at an address
    ///      of its choosing, which would consume the validation and strand the intended address
    function testDeployOtherSalt() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        salts[0] = _salt(address(deployGate), 777);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(salts[0], initCodes[0]);
    }

    /// @dev Order is the one thing an executor could otherwise still choose, and it is not inert: a
    ///      constructor reading a dependency the deployment wires would see a different value depending on
    ///      when it ran, and bake it into its runtime code. A commitment binds each contract to its position
    function testDeployOutOfOrder() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[1]));
        deployGate.deploy(salts[1], initCodes[1]);

        // The same contract deploys once the one before it has
        vm.prank(EXECUTOR);
        deployGate.deploy(salts[0], initCodes[0]);
        vm.prank(EXECUTOR);
        assertEq(Target(deployGate.deploy(salts[1], initCodes[1])).value(), 2);
        assertEq(deployGate.deployed(), 2, "the position advances with every deployment");
    }

    /// @dev A new commitment restarts the sequence, so the position left by a partial one cannot strand it
    function testValidateResetsThePosition() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        vm.prank(EXECUTOR);
        deployGate.deploy(salts[0], initCodes[0]);
        assertEq(deployGate.deployed(), 1);

        (bytes32[] memory corrected, bytes[] memory correctedInitCodes) = _pairs(2);
        corrected[0] = _salt(address(deployGate), 200);
        corrected[1] = _salt(address(deployGate), 201);
        _validate(corrected, correctedInitCodes);

        assertEq(deployGate.deployed(), 0, "the new commitment starts from its own first contract");
        assertEq(Target(_deploy(corrected, correctedInitCodes)[0]).value(), 1);
    }

    function testDeployConsumesTheValidation() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        _deploy(salts, initCodes);

        assertEq(deployGate.validated(salts[0]), bytes32(0));

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(salts[0], initCodes[0]);
    }

    /// @dev Init code is not part of the CREATE3 address derivation, only the caller and the salt are. This is
    ///      why the DeployGate keeps addresses stable when a contract is modified in a patch release, and
    ///      why the validated set has to commit to the init code.
    function testAddressIgnoresInitCode() public view {
        bytes32 salt = _salt(address(deployGate), 1);

        assertEq(
            computeCreate3Address(salt, address(deployGate)),
            ICreateX(CREATEX_ADDRESS)
                .computeCreate3Address(
                    keccak256(abi.encodePacked(uint256(uint160(address(deployGate))), salt)), CREATEX_ADDRESS
                )
        );
    }

    /// @dev CreateX only applies its permissioned deploy protection when the salt embeds the caller, hence the
    ///      salt guardian must be the DeployGate and not the transaction sender
    function testAddressDependsOnSaltGuardian() public view {
        assertTrue(
            computeCreate3Address(_salt(address(deployGate), 1), address(deployGate))
                != computeCreate3Address(_salt(ADMIN, 1), ADMIN),
            "salt guardian should determine the address"
        );
    }

    /// @dev A guardian other than the gate makes CreateX derive the address from the salt alone, which anyone
    ///      can reach. Rejected where the admin can still see it, rather than during the execute phase
    function testValidateForeignSaltGuardian(address guardian) public {
        vm.assume(guardian != address(deployGate));

        _expectInvalidSalt(_salt(guardian, 60));
    }

    /// @dev The 21st byte asks CreateX for cross-chain redeploy protection, which folds the chain id into the
    ///      address. Holding it at zero is what keeps the deployment equal across chains
    function testValidateWithRedeployProtection(uint8 flag) public {
        vm.assume(flag != 0);

        _expectInvalidSalt(bytes32(abi.encodePacked(bytes20(address(deployGate)), bytes1(flag), bytes11(uint88(61)))));
    }

    /// @dev One bad salt is enough: the commitment is signed whole, so it is refused whole
    function testValidateRejectsTheWholeSet() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(3);
        bytes32[] memory initCodeHashes = new bytes32[](3);
        for (uint256 i; i < 3; i++) {
            initCodeHashes[i] = keccak256(initCodes[i]);
        }
        salts[2] = _salt(address(0), 63);

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.InvalidSalt.selector, salts[2]));
        deployGate.validate(salts, initCodeHashes);

        assertEq(deployGate.validated(salts[0]), 0, "the good salts should not be committed either");
    }

    /// @dev Why the gate refuses those salts: without itself as guardian, CreateX derives the address from the
    ///      salt alone, so anyone can take it. Had the gate committed to one, the contract would still have
    ///      deployed, at an address that was never the gate's to give
    function testUnguardedSaltIsReachableByAnyone() public {
        bytes32 salt = _salt(address(0), 64);

        vm.prank(makeAddr("squatter"));
        address taken = create3(salt, _initCode(1));

        assertTrue(taken != computeCreate3Address(salt, address(deployGate)), "should not be scoped to the gate");
    }

    function _expectInvalidSalt(bytes32 salt) internal {
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = salt;

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.InvalidSalt.selector, salt));
        deployGate.validate(salts, new bytes32[](1));
    }
}

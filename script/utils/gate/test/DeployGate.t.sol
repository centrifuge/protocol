// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IDeployGate} from "../IDeployGate.sol";
import {DeployGate} from "../src/DeployGate.sol";
import {ICreateX} from "../../createx/ICreateX.sol";
import {CREATEX_ADDRESS} from "../../createx/CreateX.d.sol";
import {CreateXScript} from "../../createx/CreateXScript.sol";
import {
    DEPLOY_GATE_SALT,
    DEPLOY_GATE_ADDRESS,
    DEPLOY_GATE_BYTECODE,
    DEPLOY_GATE_EXTCODEHASH
} from "../DeployGate.d.sol";

contract Target {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract DeployGateTest is Test, CreateXScript {
    address immutable VALIDATOR = address(this);
    address immutable EXECUTOR = makeAddr("executor");
    bytes32 constant ID = bytes32(uint256(1));
    bytes32 constant OTHER_ID = bytes32(uint256(2));

    address immutable DELEGATE = makeAddr("delegate");
    address immutable OTHER = makeAddr("otherValidator");

    DeployGate deployGate;

    function setUp() public {
        setUpCreateXFactory();

        // Takes no arguments and grants nobody anything: whoever needs a gate deploys this very contract
        deployGate = new DeployGate();
    }

    /// @dev A gated salt is any 32 bytes: the gate is what turns it into a CreateX salt
    function _salt(uint88 name) internal pure returns (bytes32) {
        return bytes32(uint256(name));
    }

    function _initCode(uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Target).creationCode, abi.encode(value));
    }

    function _pairs(uint256 length) internal pure returns (bytes32[] memory salts, bytes[] memory initCodes) {
        salts = new bytes32[](length);
        initCodes = new bytes[](length);

        for (uint256 i; i < length; i++) {
            salts[i] = _salt(uint88(i + 1));
            initCodes[i] = _initCode(i + 1);
        }
    }

    function _executors(address who) internal pure returns (address[] memory executors) {
        executors = new address[](1);
        executors[0] = who;
    }

    function _validate(bytes32[] memory salts, bytes[] memory initCodes) internal {
        bytes32[] memory initCodeHashes = new bytes32[](initCodes.length);
        for (uint256 i; i < initCodes.length; i++) {
            initCodeHashes[i] = keccak256(initCodes[i]);
        }

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, ID, salts, initCodeHashes, _executors(EXECUTOR));
    }

    function _deploy(bytes32[] memory salts, bytes[] memory initCodes) internal returns (address[] memory targets) {
        targets = new address[](salts.length);
        for (uint256 i; i < salts.length; i++) {
            vm.prank(EXECUTOR);
            targets[i] = deployGate.deploy(VALIDATOR, ID, salts[i], initCodes[i]);
        }
    }

    // Namespaces

    function testEmptyNamespace() public view {
        assertEq(deployGate.nonce(VALIDATOR, ID), 0, "nothing validated yet");
        assertFalse(deployGate.isExecutor(VALIDATOR, ID, EXECUTOR), "and so nobody may deploy in it");
    }

    /// @dev A namespace is reachable by the account it is named after, and by nobody else until it says so
    function testOnlyTheValidatorMayCommit() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(initCodes[0]);

        vm.prank(OTHER);
        vm.expectRevert(IDeployGate.NotValidator.selector);
        deployGate.validate(VALIDATOR, ID, salts, hashes, _executors(EXECUTOR));

        _validate(salts, initCodes);
        assertTrue(deployGate.validated(VALIDATOR, ID, salts[0]) != 0, "committed where the validator lives");
        assertEq(deployGate.validated(OTHER, ID, salts[0]), 0, "and nowhere else");
    }

    /// @dev Which is how a cold validator lets a warm key sign the phase without giving up its addresses
    function testDelegateMayCommitOnItsBehalf() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(initCodes[0]);

        vm.prank(VALIDATOR);
        deployGate.setDelegate(DELEGATE, true);
        assertTrue(deployGate.isDelegate(VALIDATOR, DELEGATE));

        vm.prank(DELEGATE);
        deployGate.validate(VALIDATOR, ID, salts, hashes, _executors(EXECUTOR));

        // The commitment lands in the validator's namespace, not the delegate's: addresses do not follow
        // whoever signed
        assertTrue(deployGate.validated(VALIDATOR, ID, salts[0]) != 0, "committed for the validator");
        assertEq(deployGate.validated(DELEGATE, ID, salts[0]), 0, "not for the delegate");
        assertEq(Target(_deploy(salts, initCodes)[0]).value(), 1);
    }

    function testValidatorMayRevokeADelegate() public {
        vm.startPrank(VALIDATOR);
        deployGate.setDelegate(DELEGATE, true);
        deployGate.setDelegate(DELEGATE, false);
        vm.stopPrank();

        assertFalse(deployGate.isDelegate(VALIDATOR, DELEGATE));

        vm.prank(DELEGATE);
        vm.expectRevert(IDeployGate.NotValidator.selector);
        deployGate.validate(VALIDATOR, ID, new bytes32[](0), new bytes32[](0), new address[](0));
    }

    /// @dev `setDelegate` always writes to the caller's own namespace, so a delegate naming one names it in
    ///      its own: delegation is one level deep, and cannot be walked outwards from a single leaked key
    function testDelegateCannotNameFurtherDelegates() public {
        vm.prank(VALIDATOR);
        deployGate.setDelegate(DELEGATE, true);

        address second = makeAddr("secondDelegate");
        vm.prank(DELEGATE);
        deployGate.setDelegate(second, true);

        assertTrue(deployGate.isDelegate(DELEGATE, second), "it named one in its own namespace");
        assertFalse(deployGate.isDelegate(VALIDATOR, second), "which reaches nothing of the validator's");

        vm.prank(second);
        vm.expectRevert(IDeployGate.NotValidator.selector);
        deployGate.validate(VALIDATOR, ID, new bytes32[](0), new bytes32[](0), new address[](0));
    }

    /// @dev There is no call that takes a namespace away from the account it is named after, so a delegate
    ///      can commit but never lock the validator out of what its addresses derive from
    function testDelegateCannotDisplaceTheValidator() public {
        vm.prank(VALIDATOR);
        deployGate.setDelegate(DELEGATE, true);

        vm.prank(DELEGATE);
        deployGate.setDelegate(VALIDATOR, false);

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);
        assertTrue(deployGate.validated(VALIDATOR, ID, salts[0]) != 0, "the validator still commits");
    }

    function testSetDelegateEmitsEvent() public {
        vm.expectEmit();
        emit IDeployGate.SetDelegate(VALIDATOR, DELEGATE, true);

        vm.prank(VALIDATOR);
        deployGate.setDelegate(DELEGATE, true);
    }

    /// @dev Two namespaces are two deployments that never meet, sharing nothing but the contract
    function testNamespacesAreIndependent() public {
        bytes32 salt = _salt(1);

        assertTrue(
            deployGate.addressOf(VALIDATOR, salt) != deployGate.addressOf(OTHER, salt), "same salt, same address"
        );

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        assertEq(deployGate.validated(OTHER, ID, salts[0]), 0, "committing in one namespace should not reach another");

        // The executor of one namespace is nobody in the other
        vm.prank(EXECUTOR);
        vm.expectRevert(IDeployGate.NotExecutor.selector);
        deployGate.deploy(OTHER, ID, salts[0], initCodes[0]);
    }

    /// @dev Executors belong to the commitment, so a new one replaces them along with the salts. This is
    ///      what revoking a leaked executor key comes down to: commit again without it
    function testValidateReplacesTheExecutors() public {
        address other = makeAddr("otherExecutor");

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);
        assertTrue(deployGate.isExecutor(VALIDATOR, ID, EXECUTOR), "named by the first commitment");

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(initCodes[0]);

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, ID, salts, hashes, _executors(other));

        assertTrue(deployGate.isExecutor(VALIDATOR, ID, other), "the new one may deploy");
        assertFalse(deployGate.isExecutor(VALIDATOR, ID, EXECUTOR), "and the one it replaced may not");

        vm.prank(EXECUTOR);
        vm.expectRevert(IDeployGate.NotExecutor.selector);
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);

        vm.prank(other);
        assertEq(Target(deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0])).value(), 1);
    }

    /// @dev Committing nothing revokes the executors along with everything else, so a namespace can be shut
    ///      down in one transaction rather than one per key
    function testValidateNothingRevokesTheExecutors() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, ID, new bytes32[](0), new bytes32[](0), new address[](0));

        assertFalse(deployGate.isExecutor(VALIDATOR, ID, EXECUTOR), "nobody may deploy what nothing commits to");

        vm.prank(EXECUTOR);
        vm.expectRevert(IDeployGate.NotExecutor.selector);
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
    }

    // Commitments

    /// @dev What the id is for: a validator commits again without touching what an executor has not spent yet
    function testCommitmentsAreIndependent() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        // A second commitment, under its own id, naming salts of its own
        (bytes32[] memory other, bytes[] memory otherInitCodes) = _pairs(1);
        other[0] = _salt(500);
        bytes32[] memory otherHashes = new bytes32[](1);
        otherHashes[0] = keccak256(otherInitCodes[0]);

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, OTHER_ID, other, otherHashes, _executors(EXECUTOR));

        assertTrue(deployGate.validated(VALIDATOR, ID, salts[0]) != 0, "the first is untouched");
        assertTrue(deployGate.validated(VALIDATOR, OTHER_ID, other[0]) != 0, "and the second stands beside it");
        assertEq(deployGate.validated(VALIDATOR, OTHER_ID, salts[0]), 0, "neither reaches into the other");

        // Each carries its own cursor, so the two do not interleave
        vm.prank(EXECUTOR);
        deployGate.deploy(VALIDATOR, OTHER_ID, other[0], otherInitCodes[0]);
        assertEq(deployGate.deployed(VALIDATOR, OTHER_ID), 1);
        assertEq(deployGate.deployed(VALIDATOR, ID), 0, "the other commitment has not moved");

        assertEq(Target(_deploy(salts, initCodes)[0]).value(), 1, "and still deploys from its own first position");
    }

    /// @dev Reusing an id is what replaces a commitment, which is the whole of how one is corrected
    function testReusingAnIdReplacesTheCommitment() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);
        assertEq(deployGate.nonce(VALIDATOR, ID), 1);

        (bytes32[] memory corrected, bytes[] memory correctedInitCodes) = _pairs(1);
        corrected[0] = _salt(501);
        _validate(corrected, correctedInitCodes);

        assertEq(deployGate.nonce(VALIDATOR, ID), 2, "same id, next generation");
        assertEq(deployGate.validated(VALIDATOR, ID, salts[0]), 0, "what it replaced is gone");
    }

    /// @dev The id scopes permission, never an address: where a contract lands is the validator and the salt
    function testAddressIgnoresTheCommitmentId() public view {
        bytes32 salt = _salt(1);

        assertEq(deployGate.addressOf(VALIDATOR, salt), deployGate.addressOf(VALIDATOR, salt));
        assertEq(deployGate.createXSalt(VALIDATOR, salt), deployGate.createXSalt(VALIDATOR, salt));
    }

    // Validate

    function testValidate() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);

        _validate(salts, initCodes);

        assertEq(deployGate.validated(VALIDATOR, ID, salts[0]), deployGate.commitment(keccak256(initCodes[0]), 0));
        assertEq(deployGate.validated(VALIDATOR, ID, salts[1]), deployGate.commitment(keccak256(initCodes[1]), 1));
        assertTrue(deployGate.isExecutor(VALIDATOR, ID, EXECUTOR), "the executor may deploy it");
        assertEq(deployGate.nonce(VALIDATOR, ID), 1, "the first commitment is the first nonce");
    }

    /// @dev A validation replaces the whole previous one, so a salt dropped from the set must not linger as an
    ///      approval nobody remembers giving: an executor could otherwise spend it to strand that address
    function testValidateAgainDropsWhatItDoesNotMention() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        // A corrected set, under salts of its own, leaving both of the above behind
        (bytes32[] memory corrected, bytes[] memory correctedInitCodes) = _pairs(2);
        corrected[0] = _salt(100);
        corrected[1] = _salt(101);
        _validate(corrected, correctedInitCodes);

        assertEq(deployGate.nonce(VALIDATOR, ID), 2, "validating again starts a nonce");
        assertEq(deployGate.validated(VALIDATOR, ID, salts[0]), 0, "the dropped salts should be gone");
        assertEq(deployGate.validated(VALIDATOR, ID, salts[1]), 0, "the dropped salts should be gone");

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);

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

        vm.prank(VALIDATOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.DuplicateSalt.selector, salts[0]));
        deployGate.validate(VALIDATOR, ID, salts, initCodeHashes, _executors(EXECUTOR));
    }

    /// @dev Which is how a commitment is revoked outright, without naming a replacement for it. Keeps the
    ///      executor, so that what trips is the salt being gone rather than the executor being gone, which
    ///      testValidateNothingRevokesTheExecutors covers on its own
    function testValidateNothingRevokesEverything() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, ID, new bytes32[](0), new bytes32[](0), _executors(EXECUTOR));

        assertEq(deployGate.validated(VALIDATOR, ID, salts[0]), 0, "nothing should be left validated");

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
    }

    /// @dev Any of them may deploy any of the contracts, so the phase can be split between keys
    function testSeveralExecutors() public {
        address other = makeAddr("otherExecutor");

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(initCodes[0]);
        hashes[1] = keccak256(initCodes[1]);

        address[] memory executors = new address[](2);
        executors[0] = EXECUTOR;
        executors[1] = other;

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, ID, salts, hashes, executors);

        // Neither is confined to a subset of the commitment: they are interchangeable
        vm.prank(other);
        assertEq(Target(deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0])).value(), 1);

        vm.prank(EXECUTOR);
        assertEq(Target(deployGate.deploy(VALIDATOR, ID, salts[1], initCodes[1])).value(), 2);
    }

    function testValidateEmitsEvent() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        bytes32[] memory initCodeHashes = new bytes32[](2);
        for (uint256 i; i < 2; i++) {
            initCodeHashes[i] = keccak256(initCodes[i]);
        }

        // One event carries the whole commitment: which generation it opens, what may be deployed, and who
        // may deploy it
        vm.expectEmit();
        emit IDeployGate.Validate(VALIDATOR, ID, 1, salts, initCodeHashes, _executors(EXECUTOR));

        vm.prank(VALIDATOR);
        deployGate.validate(VALIDATOR, ID, salts, initCodeHashes, _executors(EXECUTOR));
    }

    function testValidateLengthMismatch() public {
        (bytes32[] memory salts,) = _pairs(2);

        vm.prank(VALIDATOR);
        vm.expectRevert(IDeployGate.LengthMismatch.selector);
        deployGate.validate(VALIDATOR, ID, salts, new bytes32[](1), _executors(EXECUTOR));
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

        address[] memory targets = _deploy(salts, initCodes);

        assertEq(targets.length, 3);
        for (uint256 i; i < targets.length; i++) {
            assertEq(targets[i], deployGate.addressOf(VALIDATOR, salts[i]), "unexpected address");
            assertEq(Target(targets[i]).value(), i + 1);
        }
    }

    function testDeployEmitsEvent() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.expectEmit();
        emit IDeployGate.Deploy(VALIDATOR, ID, 1, salts[0], deployGate.addressOf(VALIDATOR, salts[0]));

        _deploy(salts, initCodes);
    }

    function testDeployNotExecutor(address nonExecutor) public {
        vm.assume(nonExecutor != EXECUTOR);

        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        vm.prank(nonExecutor);
        vm.expectRevert(IDeployGate.NotExecutor.selector);
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
    }

    function testDeployNotValidated() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);

        // Only the first one is validated
        bytes32[] memory oneSalt = new bytes32[](1);
        bytes[] memory oneInitCode = new bytes[](1);
        oneSalt[0] = salts[0];
        oneInitCode[0] = initCodes[0];
        _validate(oneSalt, oneInitCode);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[1]));
        deployGate.deploy(VALIDATOR, ID, salts[1], initCodes[1]);
    }

    /// @dev Validating commits to the init code, so an executor cannot substitute the bytecode
    function testDeployOtherInitCode() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        initCodes[0] = _initCode(666);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
    }

    /// @dev Validating commits to the salt as well, so an executor cannot deploy validated code at an address
    ///      of its choosing, which would consume the validation and strand the intended address
    function testDeployOtherSalt() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        salts[0] = _salt(777);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
    }

    /// @dev Order is the one thing an executor could otherwise still choose, and it is not inert: a
    ///      constructor reading a dependency the deployment wires would see a different value depending on
    ///      when it ran, and bake it into its runtime code. A commitment binds each contract to its position
    function testDeployOutOfOrder() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[1]));
        deployGate.deploy(VALIDATOR, ID, salts[1], initCodes[1]);

        // The same contract deploys once the one before it has
        vm.prank(EXECUTOR);
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
        vm.prank(EXECUTOR);
        assertEq(Target(deployGate.deploy(VALIDATOR, ID, salts[1], initCodes[1])).value(), 2);
        assertEq(deployGate.deployed(VALIDATOR, ID), 2, "the position advances with every deployment");
    }

    /// @dev A new commitment restarts the sequence, so the position left by a partial one cannot strand it
    function testValidateResetsThePosition() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(2);
        _validate(salts, initCodes);

        vm.prank(EXECUTOR);
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
        assertEq(deployGate.deployed(VALIDATOR, ID), 1);

        (bytes32[] memory corrected, bytes[] memory correctedInitCodes) = _pairs(2);
        corrected[0] = _salt(200);
        corrected[1] = _salt(201);
        _validate(corrected, correctedInitCodes);

        assertEq(deployGate.deployed(VALIDATOR, ID), 0, "the new commitment starts from its own first contract");
        assertEq(Target(_deploy(corrected, correctedInitCodes)[0]).value(), 1);
    }

    function testDeployConsumesTheValidation() public {
        (bytes32[] memory salts, bytes[] memory initCodes) = _pairs(1);
        _validate(salts, initCodes);

        _deploy(salts, initCodes);

        assertEq(deployGate.validated(VALIDATOR, ID, salts[0]), bytes32(0));

        vm.prank(EXECUTOR);
        vm.expectRevert(abi.encodeWithSelector(IDeployGate.NotValidated.selector, salts[0]));
        deployGate.deploy(VALIDATOR, ID, salts[0], initCodes[0]);
    }

    // Addresses

    /// @dev Init code is not part of the CREATE3 address derivation, only the caller and the salt are. This is
    ///      why the DeployGate keeps addresses stable when a contract is modified in a patch release, and
    ///      why the validated set has to commit to the init code.
    function testAddressIgnoresInitCode() public view {
        bytes32 salt = _salt(1);

        assertEq(
            deployGate.addressOf(VALIDATOR, salt),
            computeCreate3Address(deployGate.createXSalt(VALIDATOR, salt), address(deployGate))
        );
    }

    /// @dev The gate names itself as the salt guardian, so CreateX derives the address from the gate as well
    ///      as from the salt. Nobody else can produce that address, whatever salt they pass
    function testAddressIsReachableOnlyThroughTheGate() public {
        bytes32 salt = _salt(64);
        bytes32 createXSalt = deployGate.createXSalt(VALIDATOR, salt);

        assertEq(address(bytes20(createXSalt)), address(deployGate), "the gate should be the salt guardian");

        vm.prank(makeAddr("squatter"));
        address taken = create3(createXSalt, _initCode(1));

        assertTrue(taken != deployGate.addressOf(VALIDATOR, salt), "should not be reachable from outside the gate");
    }

    /// @dev The 21st byte asks CreateX for cross-chain redeploy protection, which folds the chain id into the
    ///      address. Holding it at zero is what keeps a namespace equal across chains
    function testAddressIsTheSameOnEveryChain() public {
        bytes32 salt = _salt(65);
        address here = deployGate.addressOf(VALIDATOR, salt);

        assertEq(deployGate.createXSalt(VALIDATOR, salt)[20], bytes1(0x0), "redeploy protection should stay off");

        vm.chainId(block.chainid + 1);

        assertEq(deployGate.addressOf(VALIDATOR, salt), here, "the chain id must not reach the address");
    }

    /// @dev CreateX scopes the address to the caller, which is the gate, so two of them share nothing. Only
    ///      one is ever deployed, but that is what makes the address the gate's to give rather than anyone's
    function testAddressDependsOnTheGate() public {
        bytes32 salt = _salt(1);
        DeployGate other = new DeployGate();

        assertTrue(deployGate.addressOf(VALIDATOR, salt) != other.addressOf(VALIDATOR, salt), "same gate, same address");
    }

    /// @dev Two owners never collide, which is what makes one gate safe to share
    function testAddressDependsOnTheNamespace(address owner, address other, bytes32 salt) public view {
        vm.assume(owner != other);

        assertTrue(deployGate.addressOf(owner, salt) != deployGate.addressOf(other, salt));
    }

    function testAddressMatchesCreateX() public view {
        bytes32 salt = _salt(1);
        bytes32 guarded =
            keccak256(abi.encodePacked(uint256(uint160(address(deployGate))), deployGate.createXSalt(VALIDATOR, salt)));

        assertEq(deployGate.addressOf(VALIDATOR, salt), ICreateX(CREATEX_ADDRESS).computeCreate3Address(guarded));
    }
}

/// @dev What the rest of the repository holds the gate by, checked against the contract itself. Only this
///      file can: everything else deploys and verifies from the constants alone, and once the gate moves to
///      its own repository these go with it.
contract DeployGateBytecodeTest is Test, CreateXScript {
    function setUp() public {
        setUpCreateXFactory();
    }

    /// @dev The constants are hardcoded because the address is the same on every chain, which leaves them
    ///      free to drift from the contract they describe. This is what refuses to let them: change
    ///      DeployGate.sol and this fails with the values to paste into DeployGate.d.sol.
    ///
    ///      Skipped under coverage, which compiles with metadata appended, moving the init code and with it
    ///      an address that is only meaningful for the settings a real deployment uses
    function testConstantsMatchTheBytecode() public view {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;

        assertEq(DEPLOY_GATE_BYTECODE, type(DeployGate).creationCode, "DEPLOY_GATE_BYTECODE is stale");

        address computed = CreateX.computeCreate2Address(
            keccak256(abi.encode(DEPLOY_GATE_SALT)), keccak256(DEPLOY_GATE_BYTECODE), CREATEX_ADDRESS
        );

        assertEq(computed, DEPLOY_GATE_ADDRESS, "DEPLOY_GATE_ADDRESS is stale");
        assertEq(keccak256(type(DeployGate).runtimeCode), DEPLOY_GATE_EXTCODEHASH, "DEPLOY_GATE_EXTCODEHASH is stale");
    }

    /// @dev The address covers the *init* code, and the same init code can still return different runtime
    ///      code when a constructor reads state. This is what rules that out for the gate: no immutables and
    ///      nothing read, so the init code the address covers determines the runtime code as well
    function testRuntimeCodeFollowsFromInitCode() public {
        address deployed = CreateX.deployCreate2(DEPLOY_GATE_SALT, DEPLOY_GATE_BYTECODE);

        assertEq(deployed.codehash, keccak256(type(DeployGate).runtimeCode), "runtime code should be fixed");
    }
}

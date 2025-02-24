// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "src/misc/libraries/SignatureLib.sol";
import "src/misc/libraries/EIP712Lib.sol";

contract MockValidSigner {
    function isValidSignature(bytes32, bytes memory) public pure returns (bytes4) {
        return IERC1271.isValidSignature.selector;
    }
}

contract MockInvalidSigner {
    function isValidSignature(bytes32, bytes memory) public pure returns (bytes4) {
        return 0xdeadbeef; // Invalid return value
    }
}

contract MockFailingSigner {
    function isValidSignature(bytes32, bytes memory) public pure {
        revert("Signature validation failed");
    }
}

contract SignatureLibTest is Test {
    bytes32 private constant DOMAIN_SEPARATOR = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 private constant DIGEST = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes private constant DUMMY_SIGNATURE = hex"1234567890";

    bytes32 private nameHash;
    bytes32 private versionHash;
    bytes32 private domainSeparator;
    address private owner;
    uint256 private ownerPk;
    address private wrongOwner;
    uint256 private wrongOwnerPk;

    function setUp() public {
        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        domainSeparator = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
        (owner, ownerPk) = makeAddrAndKey("owner");
        (wrongOwner, wrongOwnerPk) = makeAddrAndKey("wrongOwner");
    }

    function testValidEOASignature() public view {
        bytes32 digest = _calculateTestDigest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertTrue(SignatureLib.isValidSignature(owner, digest, signature));
    }

    function testInvalidEOASignature() public view {
        bytes32 digest = _calculateTestDigest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongOwnerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertFalse(SignatureLib.isValidSignature(owner, digest, signature));
    }

    function testWrongDigestEOASignature() public view {
        bytes32 digest = _calculateTestDigest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertFalse(SignatureLib.isValidSignature(owner, keccak256("Wrong digest"), signature));
    }

    function testValidContractSignature() public {
        MockValidSigner signer = new MockValidSigner();
        bool isValid = SignatureLib.isValidSignature(address(signer), DIGEST, DUMMY_SIGNATURE);
        assertTrue(isValid);
    }

    function testInvalidContractSignature() public {
        MockInvalidSigner signer = new MockInvalidSigner();
        bool isValid = SignatureLib.isValidSignature(address(signer), DIGEST, DUMMY_SIGNATURE);
        assertFalse(isValid);
    }

    function testErrContractSignature() public {
        MockFailingSigner signer = new MockFailingSigner();
        vm.expectRevert(SignatureLib.InvalidSigner.selector);
        SignatureLib.isValidSignature(address(signer), DIGEST, DUMMY_SIGNATURE);
    }

    function testSignatureReplay() public view {
        bytes32 digest1 = _calculateTestDigest();
        bytes32 digest2 = keccak256("Different message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest1);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertTrue(SignatureLib.isValidSignature(owner, digest1, signature));
        assertFalse(SignatureLib.isValidSignature(owner, digest2, signature));
    }

    function _calculateTestDigest() private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, keccak256(abi.encode(keccak256("Test()")))));
    }
}

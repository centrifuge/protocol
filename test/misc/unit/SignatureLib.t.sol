// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "src/libraries/SignatureLib.sol";
import "src/libraries/EIP712Lib.sol";

contract SignatureLibTest is Test {
    function testIsValidSignature() public {
        bytes32 nameHash = keccak256(bytes("Centrifuge"));
        bytes32 versionHash = keccak256(bytes("1"));
        bytes32 DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
        (address owner, uint256 ownerPk) = makeAddrAndKey("owner");
        (, uint256 wrongOwnerPk) = makeAddrAndKey("wrongOwner");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            wrongOwnerPk,
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(keccak256("Test()")))))
        );
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(keccak256("Test()")))));

        assertEq(SignatureLib.isValidSignature(owner, digest, signature), false);

        (v, r, s) = vm.sign(
            ownerPk,
            keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(keccak256("Test()")))))
        );
        signature = abi.encodePacked(r, s, v);

        assertEq(SignatureLib.isValidSignature(owner, keccak256("Wrong digest"), signature), false);

        assertEq(SignatureLib.isValidSignature(owner, digest, signature), true);
    }
}

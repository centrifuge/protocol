// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../src/misc/libraries/EIP712Lib.sol";

import "forge-std/Test.sol";

contract EIP712LibTest is Test {
    function testCalculateDomainSeparator() public view {
        bytes32 nameHash = keccak256(bytes("TestContract"));
        bytes32 versionHash = keccak256(bytes("1"));

        bytes32 expectedDomainSeparator =
            keccak256(abi.encode(EIP712Lib.EIP712_DOMAIN_TYPEHASH, nameHash, versionHash, block.chainid, address(this)));

        bytes32 calculatedDomainSeparator = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
        assertEq(calculatedDomainSeparator, expectedDomainSeparator);
    }

    function testConstantDomainSeperator() public pure {
        bytes32 expectedTypehash = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
        assertEq(EIP712Lib.EIP712_DOMAIN_TYPEHASH, expectedTypehash);
    }

    function testDifferentInputs() public view {
        bytes32 nameHash1 = keccak256(bytes("Contract1"));
        bytes32 versionHash1 = keccak256(bytes("1.0"));

        bytes32 nameHash2 = keccak256(bytes("Contract2"));
        bytes32 versionHash2 = keccak256(bytes("2.0"));

        bytes32 domainSeparator1 = EIP712Lib.calculateDomainSeparator(nameHash1, versionHash1);
        bytes32 domainSeparator2 = EIP712Lib.calculateDomainSeparator(nameHash2, versionHash2);

        assertTrue(domainSeparator1 != domainSeparator2);
    }
}

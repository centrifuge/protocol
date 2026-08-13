// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {WireToNewNetwork} from "../../script/WireToNewNetwork.s.sol";

import "forge-std/Test.sol";

/// @title  WireToNewNetworkSignerTest
/// @notice Covers the local signer check that runs before a Safe proposal is submitted.
/// @dev    The signature `Safe.sign` returns is produced by `cast wallet sign --data <SafeTx JSON>`,
///         which signs exactly the digest `Safe.getSafeTxHash` returns, so plain ecrecover applies.
contract WireToNewNetworkSignerTest is WireToNewNetwork, Test {
    bytes32 constant SAFE_TX_HASH = 0xd9bb83914cc83ea142fb56eda9e4422f14c909cb1ce3099732db2100d322fba1;
    string constant PATH = "m/44'/60'/1'/0/0";

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function testAcceptsSignatureFromSender() public {
        uint256 pk = 0xA11CE;
        vm.prank(vm.addr(pk));
        this.exposedAssertSignerIsSender(SAFE_TX_HASH, _sign(pk, SAFE_TX_HASH), PATH);
    }

    function testRejectsSignatureFromAnotherKey() public {
        uint256 signerPk = 0xB0B;
        address sender = vm.addr(0xA11CE);

        vm.expectRevert(
            bytes(
                string.concat(
                    "Derivation path ",
                    PATH,
                    " signs as ",
                    vm.toString(vm.addr(signerPk)),
                    " but --sender is ",
                    vm.toString(sender)
                )
            )
        );
        vm.prank(sender);
        this.exposedAssertSignerIsSender(SAFE_TX_HASH, _sign(signerPk, SAFE_TX_HASH), PATH);
    }

    function testRejectsSignatureOverADifferentDigest() public {
        uint256 pk = 0xA11CE;
        vm.prank(vm.addr(pk));
        vm.expectRevert();
        this.exposedAssertSignerIsSender(SAFE_TX_HASH, _sign(pk, keccak256("other batch")), PATH);
    }

    function testRejectsMalformedSignature() public {
        vm.expectRevert(bytes("Unexpected signature length"));
        this.exposedAssertSignerIsSender(SAFE_TX_HASH, hex"1234", PATH);
    }

    /// @dev External wrapper so vm.prank sets msg.sender for the internal check.
    function exposedAssertSignerIsSender(bytes32 safeTxHash, bytes memory signature, string memory derivationPath)
        external
        view
    {
        _assertSignerIsSender(safeTxHash, signature, derivationPath);
    }
}

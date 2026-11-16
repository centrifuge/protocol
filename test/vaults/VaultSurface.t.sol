// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

/// @dev The specification's claim about the vault's whole published surface, checked against the
///      build artifact rather than by restating what the code says, so a setter added later fails
///      here instead of quietly contradicting the specification.
contract VaultSurfaceTest is Test {
    function _artifact(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat("out/Vault.sol/", name, ".json"));
    }

    /// @dev All configuration is set once in the constructor: there is no `file`, no setter, no
    ///      upgrade path, and reconfiguration is a new deployment.
    ///
    ///      The mutable surface a ward holds is `rely`/`deny` and `Recoverable.recoverTokens`; the
    ///      only other writer an investor can reach is `setOperator`, which is their own bookkeeping.
    ///      Everything else that writes is either a settlement callback or a claim.
    function testTheVaultPublishesNoConfigurationSetter() public view {
        string[] memory signatures = vm.parseJsonKeys(_artifact("Vault"), ".methodIdentifiers");
        assertGt(signatures.length, 10, "the vault ABI was read at all");

        for (uint256 i; i < signatures.length; i++) {
            assertFalse(_isConfigurationSetter(signatures[i]), signatures[i]);
        }
    }

    /// @dev Anything that reads as "set this piece of configuration". Deliberately crude and
    ///      deliberately broad: the point is that a name of this shape appearing at all is the signal.
    function _isConfigurationSetter(string memory signature) internal pure returns (bool) {
        bytes memory name = bytes(signature);
        if (_startsWith(name, "file(")) return true;
        if (_startsWith(name, "update")) return true;
        if (_startsWith(name, "upgrade")) return true;

        // `set` followed by a capital, so `settlementObserver()` is not mistaken for one.
        // `setOperator` matches by shape but is an investor's own bookkeeping, not configuration.
        if (_startsWith(name, "setOperator(")) return false;
        return _startsWith(name, "set") && name.length > 3 && name[3] >= 0x41 && name[3] <= 0x5A;
    }

    function _startsWith(bytes memory haystack, string memory needleStr) internal pure returns (bool) {
        bytes memory needle = bytes(needleStr);
        if (haystack.length < needle.length) return false;

        for (uint256 i; i < needle.length; i++) {
            if (haystack[i] != needle[i]) return false;
        }
        return true;
    }
}

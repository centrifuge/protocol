// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

// The path a Ledger's first account sits at. A default and nothing more: the account a Safe accepts a
// proposal from is whichever of its owners or proposers the signer holds, and that need not be the first —
// the same seed keeps an unrelated account at every path, so nothing here can know which is the owner
string constant DEFAULT_LEDGER_DERIVATION_PATH = "m/44'/60'/0'/0/0";

/// @notice Where on the Ledger the signer is. Read by everything that signs over ffi: the Safe proposals,
///         and the account they are posted as — `ledgerAddress()` asks the device what sits at this path, and
///         that is who the transaction service sees. Set LEDGER_DERIVATION_PATH when the owner is kept at
///         another path; a proposal from the wrong one is refused by the service, before anything is signed,
///         so the cost of the default being wrong is a rejected proposal and a second run
function ledgerDerivationPath() view returns (string memory) {
    return vm.envOr("LEDGER_DERIVATION_PATH", string(DEFAULT_LEDGER_DERIVATION_PATH));
}

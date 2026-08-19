// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

// The protocol's mainnet admin Safes, the same addresses on every mainnet. Named outright rather than read
// from `env/`, because a script that checks the config against them cannot take them from there
address constant PROTOCOL_SAFE = 0x9711730060C73Ee7Fcfe1890e8A0993858a7D225;
address constant OPS_SAFE = 0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16;

// The path a Ledger's first account sits at, which is only the usual one, not the only one
string constant DEFAULT_LEDGER_DERIVATION_PATH = "m/44'/60'/0'/0/0";

/// @notice Where on the Ledger the signer is, overridable because whoever signs may keep it elsewhere
function ledgerDerivationPath() view returns (string memory) {
    return vm.envOr("LEDGER_DERIVATION_PATH", string(DEFAULT_LEDGER_DERIVATION_PATH));
}

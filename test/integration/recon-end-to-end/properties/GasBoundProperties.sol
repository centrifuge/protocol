// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter} from "../BeforeAfter.sol";

/// @notice No history makes an investor's claim, a keeper's fold or a flush too expensive to execute.
/// @dev    A claim folds the controller's horizon and nothing else, so what it costs depends on the policy's horizon
///         and never on how many windows or contributors other users made. Every handler that claims, folds or flushes
///         measures the call with `gasleft()` and holds it to one ceiling. The ceiling is well above the measured
///         worst case (a claim over a full horizon of settled windows on both sides, about 1.1M) and well below the
///         12.5M an Echidna transaction may spend, so it fails on a cost that grows with history and not on the
///         cold-storage difference between a single call and one made inside a long handler.
abstract contract GasBoundProperties is BeforeAfter, Asserts {
    uint256 internal constant CLAIM_GAS_CEILING = 5_000_000;

    /// @dev The most any measured claim, fold or flush has cost so far, for the stats and the reachability tests.
    uint256 internal ghost_worstClaimGas;

    /// @dev Holds a call that cost `used` gas to the ceiling. The call may have reverted: running out of the gas the
    ///      ceiling stands for is a failure too, and a cheap refusal is not.
    function _boundGas(uint256 used, string memory reason) internal {
        if (used > ghost_worstClaimGas) ghost_worstClaimGas = used;
        lte(used, CLAIM_GAS_CEILING, reason);
    }

    /// @dev A pranked call held to the ceiling, which a handler short of stack room uses in place of `_callAs`.
    function _boundedCall(address who, address target, bytes memory data, string memory reason)
        internal
        returns (bool success, bytes memory ret)
    {
        uint256 gas0 = gasleft();
        (success, ret) = _callAs(who, target, data);
        _boundGas(gas0 - gasleft(), reason);
    }
}

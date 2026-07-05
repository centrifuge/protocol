// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ShareClassId} from "../types/ShareClassId.sol";

/// @title  ContractUpdateLib
/// @notice Encoding helpers for routing a legacy trusted contract update over the unified ManagerCall/Envoy
///         transport. A contract update is a `Hub.managerCall` whose `target` is the (deterministic, CREATE3)
///         {ContractUpdaterForwarder} address; the forwarder unwraps the payload via {unwrap} and forwards to
///         `ContractUpdater.trustedCall(poolId, scId, target, inner)`.
/// @dev    `scId` rides the payload because {IManagerCallFromHub} is pool-scoped only. The wrap shape MUST
///         stay in sync with `ContractUpdaterForwarder.fromHub` and `StdManifest._checkManagerCall`.
library ContractUpdateLib {
    /// @notice Build the `managerCall` payload for a trusted contract update.
    function wrap(ShareClassId scId, address target, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encode(scId, target, inner);
    }

    /// @notice Decode a wrapped contract update. Mirror of {wrap}.
    function unwrap(bytes memory payload)
        internal
        pure
        returns (ShareClassId scId, address target, bytes memory inner)
    {
        return abi.decode(payload, (ShareClassId, address, bytes));
    }
}

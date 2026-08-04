// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice Stateless, payable dispatcher for ManagerCall targets. The stable `msg.sender` anchor
///         targets bind to — the Hub redeploys every release and must never be the anchor.
interface IEnvoy {
    event ManagerCallFromHub(PoolId indexed poolId, address target, bytes payload);
    event ManagerCallFromSpoke(
        PoolId indexed poolId, address target, bytes payload, uint16 centrifugeId, bytes32 sender
    );

    /// @notice Forwards a hub-direction manager call to `target` with any attached value. No origin args:
    ///         already authorized at the Hub (`_enforce` + policy); origin chain is always the hub's own.
    function callFromHub(PoolId poolId, address target, bytes calldata payload) external payable;

    /// @notice Forwards an untrusted spoke-direction manager call to `target`, passing `(centrifugeId, sender)`
    ///         for the target to validate.
    function callFromSpoke(PoolId poolId, address target, bytes calldata payload, uint16 centrifugeId, bytes32 sender)
        external
        payable;
}

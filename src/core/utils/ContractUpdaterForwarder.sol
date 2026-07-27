// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ContractUpdateLib} from "./ContractUpdateLib.sol";
import {IManagerCallFromHub} from "./interfaces/IManagerCall.sol";
import {IContractUpdaterForwarder} from "./interfaces/IContractUpdate.sol";

import {IContractUpdateGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// @title  ContractUpdaterForwarder
/// @notice Bridges the unified ManagerCall/Envoy transport to the legacy trusted contract-update path
///         WITHOUT modifying the deployed {ContractUpdater}. The Envoy calls {fromHub} here; this contract
///         unwraps the `(scId, target, inner)` payload and forwards to {ContractUpdater.trustedCall}, which
///         in turn calls `target.trustedCall` with `msg.sender == contractUpdater`. Spoke targets keep their
///         existing immutable ContractUpdater anchor unchanged — nothing deployed is upgraded.
/// @dev    Must be wired as a ward of the {ContractUpdater} (a `rely`, not an upgrade) so it may call
///         `trustedCall`. Reached only through the Envoy: `Hub.managerCall` addresses this contract for a
///         contract update, and the manifest pins this address (see {StdHubManifest._checkManagerCall}). The
///         address is deterministic (CREATE3), so the same value is the target on every chain.
contract ContractUpdaterForwarder is IManagerCallFromHub, IContractUpdaterForwarder {
    address public immutable envoy;
    IContractUpdateGatewayHandler public immutable contractUpdater;

    constructor(address envoy_, IContractUpdateGatewayHandler contractUpdater_) {
        envoy = envoy_;
        contractUpdater = contractUpdater_;
    }

    /// @inheritdoc IManagerCallFromHub
    /// @dev Callable only by the Envoy. `payload` is `ContractUpdateLib.wrap(scId, target, inner)`. Carries no
    ///      value: a contract update funds no downstream message, and `trustedCall` is non-payable.
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (ShareClassId scId, address target, bytes memory inner) = ContractUpdateLib.unwrap(payload);
        contractUpdater.trustedCall(poolId, scId, target, inner);
    }
}

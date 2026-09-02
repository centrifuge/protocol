// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEnvoy} from "./interfaces/IEnvoy.sol";
import {IManagerCallFromHub, IManagerCallFromSpoke} from "./interfaces/IManagerCall.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../types/PoolId.sol";

/// @title  Envoy
/// @notice Payable, stateless dispatcher for ManagerCall targets. The stable `msg.sender` anchor
///         targets bind to: the Hub redeploys every release and must never be the anchor.
contract Envoy is Auth, IEnvoy {
    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IEnvoy
    function callFromHub(PoolId poolId, address target, bytes calldata payload) external payable auth {
        IManagerCallFromHub(target).fromHub{value: msg.value}(poolId, payload);
        emit ManagerCallFromHub(poolId, target, payload);
    }

    /// @inheritdoc IEnvoy
    function callFromSpoke(PoolId poolId, address target, bytes calldata payload, uint16 centrifugeId, bytes32 sender)
        external
        payable
        auth
    {
        IManagerCallFromSpoke(target).fromSpoke{value: msg.value}(poolId, payload, centrifugeId, sender);
        emit ManagerCallFromSpoke(poolId, target, payload, centrifugeId, sender);
    }
}

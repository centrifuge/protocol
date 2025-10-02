// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUpdateHubContract} from "./interfaces/IUpdateHubContract.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IUpdateHubContractGatewayHandler} from "../interfaces/IGatewayHandlers.sol";

/// @title HubContractUpdater
/// @notice Central executor for spoke-to-hub contract updates
contract HubContractUpdater is Auth, IUpdateHubContractGatewayHandler {
    event UpdateHubContract(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed sender, address target, bytes payload
    );

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IUpdateHubContractGatewayHandler
    /// @dev Forwards update to target contract with sender context
    function execute(PoolId poolId, ShareClassId scId, address sender, address target, bytes memory update)
        public
        auth
    {
        IUpdateHubContract(target).updateFromSpoke(poolId, scId, sender, update);
        emit UpdateHubContract(poolId, scId, sender, target, update);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUpdateContract} from "./interfaces/IUpdateContract.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IUpdateContractGatewayHandler} from "../interfaces/IGatewayHandlers.sol";

/// @title  ContractUpdater
/// @notice This contract executes authorized cross-chain contract updates by calling the update function
///         on target contracts, enabling remote configuration and state changes for pool and share
///         class specific contracts through the gateway messaging system.
contract ContractUpdater is Auth, IUpdateContractGatewayHandler {
    event UpdateContract(PoolId indexed poolId, ShareClassId indexed scId, address target, bytes payload);

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IUpdateContractGatewayHandler
    function execute(PoolId poolId, ShareClassId scId, address target, bytes memory update) public auth {
        IUpdateContract(target).update(poolId, scId, update);
        emit UpdateContract(poolId, scId, target, update);
    }
}

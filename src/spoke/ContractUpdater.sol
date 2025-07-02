// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IUpdateContractGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";

import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";

contract ContractUpdater is Auth, IUpdateContractGatewayHandler {
    event UpdateContract(PoolId indexed poolId, ShareClassId indexed scId, address target, bytes payload);

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IUpdateContractGatewayHandler
    function updateContract(PoolId poolId, ShareClassId scId, address target, bytes memory update) public auth {
        IUpdateContract(target).update(poolId, scId, update);
        emit UpdateContract(poolId, scId, target, update);
    }
}

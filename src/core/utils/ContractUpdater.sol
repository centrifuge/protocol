// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IContractUpdater, ITrustedContractUpdate} from "./interfaces/IContractUpdate.sol";

import {Auth} from "../../misc/Auth.sol";

import {IContractUpdateGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

contract ContractUpdater is Auth, IContractUpdater, IContractUpdateGatewayHandler {
    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IContractUpdateGatewayHandler
    function trustedCall(PoolId poolId, ShareClassId scId, address target, bytes memory update) public auth {
        ITrustedContractUpdate(target).trustedCall(poolId, scId, update);
        emit TrustedContractUpdate(poolId, scId, target, update);
    }
}

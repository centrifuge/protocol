// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITrustedContractUpdate, IUntrustedContractUpdate} from "./interfaces/IContractUpdate.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IContractUpdateGatewayHandler} from "../interfaces/IGatewayHandlers.sol";

contract ContractUpdater is Auth, IContractUpdateGatewayHandler {
    event TrustedContractUpdate(PoolId indexed poolId, ShareClassId indexed scId, address target, bytes payload);
    event UntrustedContractUpdate(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address target,
        bytes payload,
        uint16 centrifugeId,
        bytes32 sender
    );

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IContractUpdateGatewayHandler
    function trustedCall(PoolId poolId, ShareClassId scId, address target, bytes memory update) public auth {
        ITrustedContractUpdate(target).trustedCall(poolId, scId, update);
        emit TrustedContractUpdate(poolId, scId, target, update);
    }

    /// @inheritdoc IContractUpdateGatewayHandler
    function untrustedCall(
        PoolId poolId,
        ShareClassId scId,
        address target,
        bytes memory update,
        uint16 centrifugeId,
        bytes32 sender
    ) public auth {
        IUntrustedContractUpdate(target).untrustedCall(poolId, scId, update, centrifugeId, sender);
        emit UntrustedContractUpdate(poolId, scId, target, update, centrifugeId, sender);
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IContractUpdateGatewayHandler} from "../../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

interface ITrustedContractUpdate {
    /// @notice Triggers an update on the target contract.
    /// @dev    Sent from the trusted hub manager role.
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external;
}

interface IContractUpdater {
    event TrustedContractUpdate(PoolId indexed poolId, ShareClassId indexed scId, address target, bytes payload);
}

interface IContractUpdaterForwarder {
    error NotEnvoy();
    error UnexpectedValue();

    /// @notice The Envoy that routes manifest-supervised manager calls
    function envoy() external view returns (address);

    /// @notice The legacy ContractUpdater the unwrapped payload is forwarded to
    function contractUpdater() external view returns (IContractUpdateGatewayHandler);
}

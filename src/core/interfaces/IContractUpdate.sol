// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

interface IContractUpdate {
    error UnknownUpdateContractType();
}

interface ITrustedContractUpdate is IContractUpdate {
    /// @notice Triggers an update on the target contract.
    /// @dev    Sent from the trusted hub manager role.
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external;
}

interface IUntrustedContractUpdate is IContractUpdate {
    /// @notice Triggers an update on the target contract.
    /// @dev    Sender MUST be validated. Sent by anyone on the spoke side.
    function untrustedCall(
        PoolId poolId,
        ShareClassId scId,
        bytes calldata payload,
        uint16 centrifugeId,
        bytes32 sender
    ) external;
}

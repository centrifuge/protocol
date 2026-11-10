// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {RequestId} from "../../../core/types/RequestId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

/// @notice Optional per-pool observer notified by the {OrderBook} when a request arrives from a spoke.
/// @dev    A revert fails the request message (retryable through the gateway). Its gas is the pool's to
///         fund, through `VaultRequestRouter.extraGasLimit`. Request gating belongs in the vault's request
///         policy.
interface IRequestObserver {
    /// @notice Called once per incoming request, after the order has been recorded.
    function onRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 amount
    ) external;
}

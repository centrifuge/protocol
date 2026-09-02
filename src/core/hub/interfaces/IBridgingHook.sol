// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

struct BridgeSharesParams {
    uint16 originCentrifugeId;
    uint16 targetCentrifugeId;
    PoolId poolId;
    ShareClassId scId;
    bytes32 sender;
    bytes32 receiver;
    uint128 amount;
    uint128 extraGasLimit;
    address refund;
}

/// @dev Fields the hook is allowed to modify. Immutable routing fields (poolId, scId, chain IDs,
///      sender) are intentionally absent.
struct BridgeSharesResult {
    bytes32 receiver;
    uint128 amount;
    uint128 extraGasLimit;
    address refund;
}

interface IBridgingHook {
    /// @notice Called before forwarding a cross-chain share transfer.
    function onBridgeShares(BridgeSharesParams calldata p) external returns (BridgeSharesResult memory);
}

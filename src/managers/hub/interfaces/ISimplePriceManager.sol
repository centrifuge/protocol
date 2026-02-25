// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {INAVHook} from "./INAVManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

/// @title  ISimplePriceManager
/// @notice Manager for tracking pool metrics and share prices across multiple networks
/// @dev    Implements INAVHook to receive NAV updates and calculate share prices
interface ISimplePriceManager is INAVHook {
    event Update(
        PoolId indexed poolId, ShareClassId scId, uint128 newNAV, uint128 newIssuance, D18 newPricePoolPerShare
    );
    event Transfer(
        PoolId indexed poolId,
        ShareClassId scId,
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        uint128 sharesTransferred
    );

    error NotAuthorized();
    error InvalidShareClass();
    error MismatchedEpochs();

    struct Metrics {
        uint128 netAssetValue;
        uint128 issuance;
    }

    struct NetworkMetrics {
        uint128 netAssetValue;
        uint128 issuance;
        uint128 transferredIn;
        uint128 transferredOut;
        uint32 issueEpochsBehind;
        uint32 revokeEpochsBehind;
    }

    function metrics(PoolId poolId) external view returns (uint128 netAssetValue, uint128 issuance);
    function networkMetrics(PoolId poolId, uint16 centrifugeId)
        external
        view
        returns (
            uint128 netAssetValue,
            uint128 issuance,
            uint128 transferredIn,
            uint128 transferredOut,
            uint32 issueEpochsBehind,
            uint32 revokeEpochsBehind
        );
}

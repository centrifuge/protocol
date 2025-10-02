// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./INAVManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../../common/types/PoolId.sol";
import {ShareClassId} from "../../../common/types/ShareClassId.sol";

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
    event UpdateNetworks(PoolId indexed poolId, uint16[] networks);
    event File(bytes32 indexed what, address data);

    error InvalidShareClassCount();
    error InvalidShareClass();
    error MismatchedEpochs();
    error FileUnrecognizedParam();
    error NetworkNotFound();

    struct Metrics {
        uint128 netAssetValue;
        uint128 issuance;
    }

    struct NetworkMetrics {
        uint128 netAssetValue;
        uint128 issuance;
        uint32 issueEpochsBehind;
        uint32 revokeEpochsBehind;
    }

    function metrics(PoolId poolId) external view returns (uint128 netAssetValue, uint128 issuance);
    function networks(PoolId poolId) external view returns (uint16[] memory);
    function networkMetrics(PoolId poolId, uint16 centrifugeId)
        external
        view
        returns (uint128 netAssetValue, uint128 issuance, uint32 issueEpochsBehind, uint32 revokeEpochsBehind);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Add a network to the pool
    /// @param poolId The pool ID
    /// @param centrifugeId Centrifuge ID for the network to add
    function addNetwork(PoolId poolId, uint16 centrifugeId) external;

    /// @notice Remove a network from the pool
    /// @param poolId The pool ID
    /// @param centrifugeId Centrifuge ID for the network to remove
    function removeNetwork(PoolId poolId, uint16 centrifugeId) external;

    function file(bytes32 what, address data) external;
}

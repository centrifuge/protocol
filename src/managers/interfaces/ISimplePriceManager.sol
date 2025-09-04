// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../misc/types/D18.sol";
import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {INAVHook} from "./INavManager.sol";

interface ISimplePriceManager is INAVHook {
    error InvalidShareClassCount();

    struct NetworkMetrics {
        D18 netAssetValue;
        uint128 issuance;
    }

    // function poolId() external view returns (PoolId);
    // function scId() external view returns (ShareClassId);
    // function networks(uint256 index) external view returns (uint16);
    // function globalIssuance() external view returns (uint128);
    // function globalNetAssetValue() external view returns (D18);

    function setNetworks(uint16[] calldata centrifugeIds) external;
}

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ChainId, PoolId, ShareClassId, AssetId, Ratio} from "src/types/Domain.sol";

interface IPoolManager {
    error NotAllowed();

    function createPool() external returns (PoolId poolId);

    function allowPool(ChainId chainId) external;

    function allowShareClass(ChainId chainId, ShareClassId scId) external;

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external;

    function approveDepositRequests(PoolId poolId, ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function updateHoldings(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 amount) external;

    function issueShares() external;

    function claimShares() external;
}

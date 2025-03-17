// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

/// @notice Entry point to the system
interface IPoolRouter {
    /// @notice Main method to unlock the pool and call the rest of the admin methods
    function execute(PoolId poolId, bytes[] calldata data) external payable;

    /// @notice See counterpart in PoolManager contract
    function createPool(AssetId currency, IShareClassManager shareClassManager)
        external
        payable
        returns (PoolId poolId);

    /// @notice See counterpart in PoolManager contract
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable;

    /// @notice See counterpart in PoolManager contract
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external payable;
}

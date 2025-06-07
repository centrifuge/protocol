// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

interface IRequestManager {
    error UnknownRequestCallbackType();

    /// @notice TODO
    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}

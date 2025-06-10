// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

interface IRequestCallback {
    error UnknownRequestCallbackType();

    /// @notice Handles a request callback originating from the Hub side.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The payload to be processed by the request callback
    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}

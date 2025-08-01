// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

interface IRequestManager {
    error UnknownRequestCallbackType();

    /// @notice Handles a request callback originating from the Hub side.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The payload to be processed by the request callback
    function callback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}

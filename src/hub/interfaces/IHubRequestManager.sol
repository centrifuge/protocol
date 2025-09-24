// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IHubRequestManager {
    /// @notice Handles a request originating from the Hub side, similar to HubHelpers.request
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}

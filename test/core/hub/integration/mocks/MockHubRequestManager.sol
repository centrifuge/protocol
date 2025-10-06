// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";
import {IHubRequestManager} from "../../../../../src/core/hub/interfaces/IHubRequestManager.sol";

contract MockHubRequestManager is IHubRequestManager {
    function request(PoolId, ShareClassId, AssetId, bytes calldata) external {}

    function callFromHub(PoolId, bytes memory) external {}

    function supportsInterface(bytes4) public pure returns (bool) {
        return true;
    }
}

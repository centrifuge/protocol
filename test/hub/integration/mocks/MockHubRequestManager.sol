// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../../src/common/types/ShareClassId.sol";

import {IHubRequestManager} from "../../../../src/hub/interfaces/IHubRequestManager.sol";

contract MockHubRequestManager is IHubRequestManager {
    function request(PoolId, ShareClassId, AssetId, bytes calldata) external override {}

    function supportsInterface(bytes4) public pure returns (bool) {
        return true;
    }
}

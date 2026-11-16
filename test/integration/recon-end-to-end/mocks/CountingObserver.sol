// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

import {IRequestObserver} from "../../../../src/vaults/hub/interfaces/IRequestObserver.sol";

/// @dev A hub-side request observer that only counts what it is told, so the observer slot is exercised
///      without constraining the requests it watches.
contract CountingObserver is IRequestObserver {
    uint256 public calls;
    uint256 public deposits;

    function onRequest(PoolId, ShareClassId, AssetId, RequestId, bool isDeposit, uint128) external {
        calls++;
        if (isDeposit) deposits++;
    }
}

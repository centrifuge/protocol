// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

import {IRequestObserver} from "../../../../src/vaults/hub/interfaces/IRequestObserver.sol";

/// @dev A hub-side request observer that refuses every request, so the request message that reaches it fails after
///      the vault has already queued and flushed the bucket it carries.
contract RevertingObserver is IRequestObserver {
    error Refused();

    function onRequest(PoolId, ShareClassId, AssetId, RequestId, bool, uint128) external pure {
        revert Refused();
    }
}

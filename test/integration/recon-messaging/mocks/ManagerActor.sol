// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";

/// @dev Non-ward actor for the pool-manager path. The test contract is a ward, so its calls pass
///      `onlyAuthOrManager` regardless of manager state; this proxy's succeed iff it holds the role.
contract ManagerActor {
    IMultiAdapter public immutable multiAdapter;

    constructor(IMultiAdapter multiAdapter_) {
        multiAdapter = multiAdapter_;
    }

    function handleAs(uint16 centrifugeId, bytes calldata payload, IAdapter adapter) external {
        multiAdapter.handle(centrifugeId, payload, adapter);
    }
}

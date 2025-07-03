// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BiasedTargetFunctions} from "./targets/BiasedTargetFunctions.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import {Properties} from "./Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// TODO: Needs to be updated for latest version of Aggregator
abstract contract TargetFunctions is BaseTargetFunctions, Properties, BiasedTargetFunctions {
    // @todo: re-enable
    // function routerAggregator_deny(address user) public {
    //     routerAggregator.deny(user);
    // }

    // function routerAggregator_disputeMessageRecovery(address router, bytes32 messageHash) public {
    //     routerAggregator.disputeMessageRecovery(CENTRIFUGE_ID, IAdapter(router), messageHash);
    // }

    // function routerAggregator_executeMessageRecovery(address router, bytes memory message) public {
    //     routerAggregator.executeMessageRecovery(CENTRIFUGE_ID, IAdapter(router), message);
    // }

    // @todo: re-enable
    // function routerAggregator_file(bytes32 what, address[] memory routers_) public {
    //     routerAggregator.file(what, routers_);
    // }

    function routerAggregator_handle(uint16 centrifugeId, bytes memory payload) public {
        routerAggregator.handle(centrifugeId, payload);
    }

    // @todo: re-enable
    // function routerAggregator_rely(address user) public {
    //     routerAggregator.rely(user);
    // }

    function routerAggregator_send(uint16 centrifugeId, bytes memory message) public {
        routerAggregator.send(centrifugeId, message);
    }
}

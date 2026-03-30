// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {MultiAdapterTargets} from "./targets/MultiAdapterTargets.sol";
import {GatewayTargets} from "./targets/GatewayTargets.sol";
import {MessagingProperties} from "./properties/MessagingProperties.sol";

abstract contract TargetFunctions is MultiAdapterTargets, GatewayTargets, MessagingProperties {}

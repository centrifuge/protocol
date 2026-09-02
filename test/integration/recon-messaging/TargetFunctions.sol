// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {GatewayTargets} from "./targets/GatewayTargets.sol";
import {MessagingProperties} from "./properties/MessagingProperties.sol";

/// @dev GatewayTargets pulls in MultiAdapterTargets transitively.
abstract contract TargetFunctions is GatewayTargets, MessagingProperties {}

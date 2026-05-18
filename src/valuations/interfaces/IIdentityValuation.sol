// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "../../core/hub/interfaces/IValuation.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";

/// @notice An IERC7726 valuation that always values 1:1.
interface IIdentityValuation is IValuation {
    /// @notice Registry of pools, assets, and manager permissions on the hub chain
    function hubRegistry() external view returns (IHubRegistry);
}

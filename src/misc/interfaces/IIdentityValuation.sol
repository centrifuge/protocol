// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IValuation} from "src/common/interfaces/IValuation.sol";

/// @notice An IERC7726 valuation that always values 1:1.
interface IIdentityValuation is IValuation {}

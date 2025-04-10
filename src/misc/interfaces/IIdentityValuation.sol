// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

/// @notice An IERC7726 valuation that always values 1:1.
interface IIdentityValuation is IERC7726 {}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC7726} from "src/interfaces/IERC7726.sol";

/// @notice An IERC7726 valuation that always values 1:1.
interface IOneToOneValuation is IERC7726 {}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "../../common/interfaces/IValuation.sol";

/// @notice An IERC7726 valuation that always values 1:1.
interface IIdentityValuation is IValuation {}

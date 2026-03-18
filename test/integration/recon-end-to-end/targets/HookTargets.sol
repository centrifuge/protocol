// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @title  HookTargets
/// @notice Fuzz targets for BaseTransferHook transfer classification invariants.
abstract contract HookTargets is BaseTargetFunctions, Properties {
    /// @notice Fuzzes (from, to) and asserts at most one is* classifier returns true.
    /// @dev    HOOK-1: Transfer classification mutual exclusivity.
    ///         Known overlaps exist with isRedeemRequest (only checks `to == ESCROW_HOOK_ID`),
    ///         which can overlap with isDepositRequestOrIssuance, isDepositClaim, and
    ///         isCrosschainTransferExecution when to == ESCROW_HOOK_ID.
    function hook_classifyTransfer(address from, address to) public {
        uint256 trueCount = 0;

        if (fullRestrictions.isDepositRequestOrIssuance(from, to)) trueCount++;
        if (fullRestrictions.isDepositFulfillment(from, to)) trueCount++;
        if (fullRestrictions.isDepositClaim(from, to)) trueCount++;
        if (fullRestrictions.isRedeemRequest(from, to)) trueCount++;
        if (fullRestrictions.isRedeemFulfillment(from, to)) trueCount++;
        if (fullRestrictions.isRedeemClaimOrRevocation(from, to)) trueCount++;
        if (fullRestrictions.isCrosschainTransfer(from, to)) trueCount++;
        if (fullRestrictions.isCrosschainTransferExecution(from, to)) trueCount++;

        t(trueCount <= 1, "HOOK-1: Transfer classification not mutually exclusive");
    }
}

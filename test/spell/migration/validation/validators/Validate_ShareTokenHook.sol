// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Spoke} from "../../../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {IShareToken} from "../../../../../src/core/spoke/interfaces/IShareToken.sol";
import {ShareClassId, newShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {BaseValidator} from "../BaseValidator.sol";

/// @title Validate_ShareTokenHook
/// @notice Validates shareToken hook migration from v3.0.1 to v3.1
/// @dev POST-only validator - verifies shareToken hooks were migrated to new versions
/// @dev Validates hooks are updated to new addresses: freezeOnly, fullRestrictions, freelyTransferable, redemptionRestrictions
contract Validate_ShareTokenHook is BaseValidator {
    function supportedPhases() public pure override returns (Phase) {
        return Phase.POST;
    }

    function name() public pure override returns (string memory) {
        return "ShareTokenHook";
    }

    function validate(ValidationContext memory ctx) public view override returns (ValidationResult memory) {
        // Pre-allocate errors: one error per pool
        ValidationError[] memory errors = new ValidationError[](ctx.pools.length);
        uint256 errorCount = 0;

        Spoke oldSpoke = Spoke(ctx.old.inner.spoke);
        Spoke newSpoke = ctx.latest.core.spoke;

        for (uint256 i = 0; i < ctx.pools.length; i++) {
            PoolId pid = ctx.pools[i];

            if (!oldSpoke.isPoolActive(pid)) continue;

            // Only validate the first share class
            ShareClassId scid = newShareClassId(pid, 1);

            errorCount = _validateShareTokenHook(ctx, oldSpoke, newSpoke, pid, scid, errors, errorCount);
        }

        return ValidationResult({
            passed: errorCount == 0, validatorName: "ShareTokenHook (POST)", errors: _trimErrors(errors, errorCount)
        });
    }

    function _validateShareTokenHook(
        ValidationContext memory ctx,
        Spoke oldSpoke,
        Spoke newSpoke,
        PoolId pid,
        ShareClassId scid,
        ValidationError[] memory errors,
        uint256 errorCount
    ) internal view returns (uint256) {
        string memory shareTokenIdStr = string.concat(
            "Pool ", _toString(PoolId.unwrap(pid)), " SC ", _toString(uint128(ShareClassId.unwrap(scid)))
        );

        try oldSpoke.shareToken(pid, scid) returns (IShareToken oldShareToken) {
            try newSpoke.shareToken(pid, scid) returns (IShareToken newShareToken) {
                address oldHook = oldShareToken.hook();
                address newHook = newShareToken.hook();
                address expectedNewHook = _getExpectedNewHook(ctx, oldHook);

                if (oldHook == address(0) || expectedNewHook == address(0)) {
                    // No hook was set, or an unknown hook was set and thus not expected to have been migrated
                    return errorCount;
                }

                if (newHook != expectedNewHook) {
                    errors[errorCount++] = _buildError({
                        field: "hook",
                        value: shareTokenIdStr,
                        expected: vm.toString(expectedNewHook),
                        actual: vm.toString(newHook),
                        message: string.concat(shareTokenIdStr, " hook not migrated correctly")
                    });
                }
            } catch {
                // New share token not found, handled by Validate_Spoke
            }
        } catch {
            // Old share token not found, skip
        }

        return errorCount;
    }

    function _getExpectedNewHook(ValidationContext memory ctx, address oldHook) internal pure returns (address) {
        if (oldHook == ctx.old.inner.freezeOnly) {
            return address(ctx.latest.freezeOnlyHook);
        } else if (oldHook == ctx.old.inner.fullRestrictions) {
            return address(ctx.latest.fullRestrictionsHook);
        } else if (oldHook == ctx.old.inner.freelyTransferable) {
            return address(ctx.latest.freelyTransferableHook);
        } else if (oldHook == ctx.old.inner.redemptionRestrictions) {
            return address(ctx.latest.redemptionRestrictionsHook);
        } else {
            return address(0);
        }
    }
}

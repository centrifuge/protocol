// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";

import {VaultGraphQLData} from "../../../../../script/spell/MigrationQueries.sol";

import {BaseValidator} from "../BaseValidator.sol";

interface IAsyncRequestManagerV3Redeem {
    function investments(address vault, address investor)
        external
        view
        returns (
            uint256 maxMint,
            uint128 maxWithdraw,
            uint128 pendingDepositRequest,
            uint128 pendingCancelDepositRequest,
            uint128 pendingCancelRedeemRequest
        );
}

/// @title Validate_UnclaimedRedeemOrders
/// @notice Validates that no users have unclaimed redeem orders (fulfilled but not claimed)
/// @dev Checks on-chain maxWithdraw values in AsyncRequestManager.investments[vault][user]
/// @dev This validator queries whitelisted investors and investorTransactions from the indexer,
///      then verifies on-chain state to catch discrepancies (indexer may show orders as "claimed"
///      when on-chain maxWithdraw is still non-zero)
contract Validate_UnclaimedRedeemOrders is BaseValidator {
    ValidationError[] internal _errors;
    uint256 internal _errorCount;

    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;
    }

    function name() public pure override returns (string memory) {
        return "UnclaimedRedeemOrders";
    }

    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        VaultGraphQLData[] memory vaults = ctx.queryService.linkedVaultsWithMetadata();
        if (vaults.length == 0) {
            return ValidationResult({passed: true, validatorName: name(), errors: new ValidationError[](0)});
        }

        address asyncReqMgrAddr = ctx.old.inner.asyncRequestManager;

        for (uint256 i = 0; i < vaults.length; i++) {
            _checkVaultInvestors(ctx, asyncReqMgrAddr, vaults[i]);
        }

        ValidationError[] memory resultErrors = new ValidationError[](_errorCount);
        for (uint256 i = 0; i < _errorCount; i++) {
            resultErrors[i] = _errors[i];
        }

        return ValidationResult({passed: _errorCount == 0, validatorName: name(), errors: resultErrors});
    }

    function _checkVaultInvestors(ValidationContext memory ctx, address asyncReqMgrAddr, VaultGraphQLData memory v)
        internal
    {
        PoolId poolId = PoolId.wrap(v.poolIdRaw);
        address[] memory investors = _getInvestorsForPool(ctx, poolId);

        IAsyncRequestManagerV3Redeem asyncReqMgr = IAsyncRequestManagerV3Redeem(asyncReqMgrAddr);

        for (uint256 j = 0; j < investors.length; j++) {
            _checkInvestorState(asyncReqMgr, v.vault, investors[j], v.poolIdRaw);
        }
    }

    function _checkInvestorState(
        IAsyncRequestManagerV3Redeem asyncReqMgr,
        address vault,
        address investor,
        uint64 poolIdRaw
    ) internal {
        try asyncReqMgr.investments(vault, investor) returns (
            uint256, /* maxMint */
            uint128 maxWithdraw,
            uint128, /* pendingDepositRequest */
            uint128, /* pendingCancelDepositRequest */
            uint128 pendingCancelRedeemRequest
        ) {
            if (maxWithdraw > 0) {
                _addMaxWithdrawError(vault, investor, maxWithdraw, poolIdRaw);
            }

            if (pendingCancelRedeemRequest > 0) {
                _addPendingCancelError(vault, investor, pendingCancelRedeemRequest, poolIdRaw);
            }
        } catch {
            // Silently skip if call fails (vault may not be registered)
        }
    }

    function _addMaxWithdrawError(address vault, address investor, uint128 maxWithdraw, uint64 poolIdRaw) internal {
        _errors.push(
            _buildError({
                field: "maxWithdraw",
                value: string.concat("Vault ", _addressToString(vault), " / User ", _addressToString(investor)),
                expected: "0",
                actual: _toString(uint256(maxWithdraw)),
                message: string.concat("User has UNCLAIMED revoked assets (maxWithdraw) - Pool ", _toString(poolIdRaw))
            })
        );
        _errorCount++;
    }

    function _addPendingCancelError(
        address vault,
        address investor,
        uint128 pendingCancelRedeemRequest,
        uint64 poolIdRaw
    ) internal {
        _errors.push(
            _buildError({
                field: "pendingCancelRedeemRequest",
                value: string.concat("Vault ", _addressToString(vault), " / User ", _addressToString(investor)),
                expected: "0",
                actual: _toString(uint256(pendingCancelRedeemRequest)),
                message: string.concat("User has PENDING cancel redeem request - Pool ", _toString(poolIdRaw))
            })
        );
        _errorCount++;
    }

    function _getInvestorsForPool(ValidationContext memory ctx, PoolId poolId)
        internal
        returns (address[] memory investors)
    {
        address[] memory whitelisted = ctx.queryService.whitelistedInvestorsByPool(poolId);
        address[] memory fromTransactions = ctx.queryService.investorsByTransactionHistory(poolId);

        return _mergeAndDeduplicateInvestors(whitelisted, fromTransactions);
    }

    function _mergeAndDeduplicateInvestors(address[] memory arr1, address[] memory arr2)
        internal
        pure
        returns (address[] memory result)
    {
        uint256 totalLen = arr1.length + arr2.length;
        if (totalLen == 0) {
            return new address[](0);
        }

        address[] memory combined = new address[](totalLen);
        uint256 idx = 0;

        for (uint256 i = 0; i < arr1.length; i++) {
            combined[idx++] = arr1[i];
        }

        for (uint256 i = 0; i < arr2.length; i++) {
            bool isDupe = false;
            for (uint256 j = 0; j < arr1.length; j++) {
                if (arr2[i] == arr1[j]) {
                    isDupe = true;
                    break;
                }
            }
            if (!isDupe) {
                combined[idx++] = arr2[i];
            }
        }

        result = new address[](idx);
        for (uint256 i = 0; i < idx; i++) {
            result[i] = combined[i];
        }
    }

    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory result = new bytes(42);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            result[2 + i * 2] = alphabet[uint8(uint160(addr) >> (8 * (19 - i)) >> 4) & 0xf];
            result[3 + i * 2] = alphabet[uint8(uint160(addr) >> (8 * (19 - i))) & 0xf];
        }
        return string(result);
    }
}

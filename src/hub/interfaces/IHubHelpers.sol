// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {HoldingAccount} from "src/hub/interfaces/IHoldings.sol";

interface IHubHelpers {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    error UnknownRequestType();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'hub'
    function file(bytes32 what, address data) external;

    /// @notice Notify a deposit for an investor address located in the chain where the asset belongs
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        returns (uint128 totalPayoutShareAmount, uint128 totalPaymentAssetAmount, uint128 cancelledAssetAmount);

    /// @notice Notify a redemption for an investor address located in the chain where the asset belongs
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        returns (uint128 totalPayoutAssetAmount, uint128 totalPaymentShareAmount, uint128 cancelledShareAmount);

    function updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external;

    function updateAccountingValue(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external;

    /// @notice Handles a request originating from the Spoke side.
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;

    function holdingAccounts(
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) external pure returns (HoldingAccount[] memory accounts);

    function liabilityAccounts(AccountId expenseAccount, AccountId liabilityAccount)
        external
        pure
        returns (HoldingAccount[] memory accounts);

    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18);
}

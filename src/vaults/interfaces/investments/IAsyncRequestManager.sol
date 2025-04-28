// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IInvestmentManagerGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";

import {IAsyncDepositManager} from "src/vaults/interfaces/investments/IAsyncDepositManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

/// @dev Vault requests and deposit/redeem bookkeeping per user
struct AsyncInvestmentState {
    /// @dev Shares that can be claimed using `mint()`
    uint128 maxMint;
    /// @dev Assets that can be claimed using `withdraw()`
    uint128 maxWithdraw;
    /// @dev Weighted average price of deposits, used to convert maxMint to maxDeposit
    /// @dev Represents priceAssetPerShare, i.e. ASSET_UNIT/SHARE_UNIT
    uint256 depositPrice;
    /// @dev Weighted average price of redemptions, used to convert maxWithdraw to maxRedeem
    /// @dev Represents priceAssetPerShare, i.e. ASSET_UNIT/SHARE_UNIT
    uint256 redeemPrice;
    /// @dev Remaining deposit request in assets
    uint128 pendingDepositRequest;
    /// @dev Remaining redeem request in shares
    uint128 pendingRedeemRequest;
    /// @dev Assets that can be claimed using `claimCancelDepositRequest()`
    uint128 claimableCancelDepositRequest;
    /// @dev Shares that can be claimed using `claimCancelRedeemRequest()`
    uint128 claimableCancelRedeemRequest;
    /// @dev Indicates whether the depositRequest was requested to be cancelled
    bool pendingCancelDepositRequest;
    /// @dev Indicates whether the redeemRequest was requested to be cancelled
    bool pendingCancelRedeemRequest;
}

interface IAsyncRequestManager is IAsyncDepositManager, IAsyncRedeemManager, IInvestmentManagerGatewayHandler {
    error AssetMismatch();
    error VaultAlreadyExists();
    error VaultDoesNotExist();
    error ZeroAmountNotAllowed();
    error TransferNotAllowed();
    error CancellationIsPending();
    error NoPendingRequest();
    error ShareTokenAmountIsZero();
    error FailedRedeemRequest();
    error ExceedsDepositLimits();
    error ShareTokenTransferFailed();
    error ExceedsMaxRedeem();
    error ExceedsRedeemLimits();

    /// @notice Returns the investment state
    function investments(IBaseVault vaultAddr, address investor)
        external
        view
        returns (
            uint128 maxMint,
            uint128 maxWithdraw,
            uint256 depositPrice,
            uint256 redeemPrice,
            uint128 pendingDepositRequest,
            uint128 pendingRedeemRequest,
            uint128 claimableCancelDepositRequest,
            uint128 claimableCancelRedeemRequest,
            bool pendingCancelDepositRequest,
            bool pendingCancelRedeemRequest
        );
}

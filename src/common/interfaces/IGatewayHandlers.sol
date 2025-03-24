// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";

/// -----------------------------------------------------
///  CP Handlers
/// -----------------------------------------------------

/// @notice Interface for CP methods called by the gateway
interface IPoolRouterGatewayHandler {
    /// @notice Tells that an asset was already registered in CV, in order to perform the corresponding register.
    /// @dev The same asset can be re-registered using this. Decimals can not change.
    function registerAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals) external;

    /// @notice Perform a deposit that was requested from CV.
    function depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount)
        external;

    /// @notice Perform a redeem that was requested from CV.
    function redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount)
        external;

    /// @notice Perform a deposit cancellation that was requested from CV.
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external;

    /// @notice Perform a redeem cancellation that was requested from CV.
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) external;
}

/// -----------------------------------------------------
///  CV Handlers
/// -----------------------------------------------------

/// @notice Interface for CV methods related to pools called by the gateway
interface IPoolManagerGatewayHandler {
    /// @notice    New pool details from an existing Centrifuge pool are added.
    /// @dev       The function can only be executed by the gateway contract.
    function addPool(uint64 poolId) external;

    /// @notice     New tranche details from an existing Centrifuge pool are added.
    /// @dev        The function can only be executed by the gateway contract.
    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) external returns (address);

    /// @notice   Updates the tokenName and tokenSymbol of a tranche token
    /// @dev      The function can only be executed by the gateway contract.
    function updateTrancheMetadata(uint64 poolId, bytes16 trancheId, string memory tokenName, string memory tokenSymbol)
        external;

    /// @notice  Updates the price of a tranche token
    /// @dev     The function can only be executed by the gateway contract.
    function updateTranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId, uint128 price, uint64 computedAt)
        external;

    /// @notice Updates the hook of a tranche token
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  hook The new hook addres
    function updateTrancheHook(uint64 poolId, bytes16 trancheId, address hook) external;

    /// @notice Updates the restrictions on a tranche token for a specific user
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  update The restriction update in the form of a bytes array indicating
    ///                the restriction to be updated, the user to be updated, and a validUntil timestamp.
    function updateRestriction(uint64 poolId, bytes16 trancheId, bytes memory update) external;

    /// @notice Mints tranche tokens to a recipient
    /// @dev    The function can only be executed internally or by the gateway contract.
    function handleTransferTrancheTokens(uint64 poolId, bytes16 trancheId, address destinationAddress, uint128 amount)
        external;

    /// @notice Updates the target address. Generic update function from CP to CV
    /// @param  poolId The centrifuge pool id
    /// @param  trancheId The tranche id
    /// @param  target The target address to be called
    /// @param  update The payload to be processed by the target address
    function updateContract(uint64 poolId, bytes16 trancheId, address target, bytes memory update) external;
}

/// @notice Interface for CV methods related to investment called by the gateway
interface IInvestmentManagerGatewayHandler {
    /// @notice Fulfills pending deposit requests after successful epoch execution on CP.
    ///         The amount of shares that can be claimed by the user is minted and moved to the escrow contract.
    ///         The MaxMint bookkeeping value is updated.
    ///         The request fulfillment can be partial.
    /// @dev    The shares in the escrow are reserved for the user and are transferred to the user on deposit
    ///         and mint calls.
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) external;

    /// @notice Fulfills pending redeem requests after successful epoch execution on CP.
    ///         The amount of redeemed shares is burned. The amount of assets that can be claimed by the user in
    ///         return is locked in the escrow contract. The MaxWithdraw bookkeeping value is updated.
    ///         The request fulfillment can be partial.
    /// @dev    The assets in the escrow are reserved for the user and are transferred to the user on redeem
    ///         and withdraw calls.
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) external;

    /// @notice Fulfills deposit request cancellation after successful epoch execution on CP.
    ///         The amount of assets that can be claimed by the user is locked in the escrow contract.
    ///         Updates claimableCancelDepositRequest bookkeeping value. The cancellation order execution can be
    ///         partial.
    /// @dev    The assets in the escrow are reserved for the user and are transferred to the user during
    ///         claimCancelDepositRequest calls.
    ///         `fulfillment` represents the decrease in `pendingDepositRequest`.
    ///         This is a separate parameter from `assets` since there can be some precision loss when calculating this,
    ///         which would lead to having dust in the pendingDepositRequest value and
    ///         never closing out the request even after it is technically fulfilled.
    ///
    ///         Example:
    ///         User deposits 100 units of the vaults underlying asset.
    ///         - At some point they make cancellation request. The order in which is not guaranteed
    ///         Both requests arrive at CentrifugeChain. If the cancellation is first then all of the
    ///         deposited amount will be cancelled.
    ///
    ///         - There is the case where the deposit event is first and it gets completely fulfilled then
    ///         No amount of the deposited asset will be cancelled.
    ///
    ///         - There is the case where partially the deposit request is fulfilled. Let's say 40 units.
    ///         Then the cancel request arrives.
    ///         The remaining amount of deposited funds which is 60 units will cancelled.
    ///         There is a scenario where the deposit funds might different from the pool currency so some
    ///         swapping might happen. Either during this swapping or some fee collection or rounding there will be
    ///         difference between the actual amount that will be returned to the user.
    ///         `fulfillment` in this case will be 60 units but assets will be some lower amount because of the
    ///         aforementioned reasons
    ///         Let's assume the `asset` is 59. The user will be able to take back these 59 but
    ///         in order to not let any dust, we use `fulfillment` in our calculations.
    ///
    ///         `pendingDepositRequest` not necessary gets zeroed during this cancellation event.
    ///         When CentrifugeChain process the cancel event on its side, part of the deposit might be fulfilled.
    ///         In such case the chain will send two messages, one `fulfillDepositRequest` and one
    ///         `fulfillCancelDepositRequest`. In the example above, given the 100 units
    ///         deposited, 40 units are fulfilled and 60 can be cancelled.
    ///         The two messages sent from CentrifugeChain are not guaranteed to arrive in order.
    ///
    ///         Assuming first is the `fulfillCancelDepositRequest` the `pendingDepositRequest` here will be reduced to
    ///         60 units only. Then the `fulfillCancelDepositRequest` arrives with `fulfillment` 60. This amount is
    ///         removed from `pendingDepositRequests`. Since there are not more pendingDepositRequest` the
    ///         `pendingCancelDepositRequest` gets deleted.
    ///
    ///         Assuming first the `fulfillCancelDepositRequest` arrives then the `pendingDepositRequest` will be 100.
    ///         `fulfillment` is 60 so we are left with `pendingDepositRequest` equals to 40 ( 100 - 60 ).
    ///         Then the second message arrives which is `fulfillDepositRequest`. ( Check `fulfillDepositRequest`
    ///         implementation for details.)
    ///         When it arrives the `pendingDepositRequest` is 40 and the assets is 40
    ///         so there are no more `pendingDepositRequest` and right there the `pendingCancelDepositRequest will be
    ///         deleted.
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) external;

    /// @notice Fulfills redeem request cancellation after successful epoch execution on CP.
    ///         The amount of shares that can be claimed by the user is locked in the escrow contract.
    ///         Updates claimableCancelRedeemRequest bookkeeping value. The cancellation order execution can also be
    ///         partial.
    /// @dev    The shares in the escrow are reserved for the user and are transferred to the user during
    ///         claimCancelRedeemRequest calls.
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        external;

    /// @notice Triggers a redeem request on behalf of the user through Centrifuge governance.
    ///         This function is required for legal/compliance reasons and rare scenarios, like share contract
    ///         migrations.
    ///         Once the next epoch is executed on Centrifuge, vaults can proceed with asset payouts in case the orders
    ///         got fulfilled.
    /// @dev    The user share amount required to fulfill the redeem request has to be locked in escrow,
    ///         even though the asset payout can only happen after epoch execution.
    function triggerRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        external;
}

/// @notice Interface for CV methods related to epoch called by the gateway
interface IBalanceSheetManagerGatewayHandler {
    function deposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata meta
    ) external;

    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        bool asAllowance,
        Meta calldata m
    ) external;

    function triggerIssueShares(PoolId poolId, ShareClassId scId, address to, uint128 shares, bool asAllowance)
        external;

    function triggerRevokeShares(PoolId poolId, ShareClassId scId, address from, uint128 shares) external;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {D18, d18} from "src/types/D18.sol";
import {PoolId} from "src/types/PoolId.sol";

// TODO(@wischli): Explore idea of single ratio for redemptions and deposits as either is always zero due to epoch id
// incrementing afer approval
struct Epoch {
    // @dev Percentage of approved redemptions
    D18 redeemRatio;
    // @dev Percentage of approved deposits
    D18 depositRatio;
    // @dev Price of one asset per pool token
    D18 assetToPoolQuote;
    // @dev Price of one share class per asset
    D18 shareClassToAssetQuote;
    // @dev Amount of approved deposits (in pool denomination)
    uint256 approvedDeposits;
}

struct UserOrder {
    // @dev Index of epoch in which last order was made
    uint32 lastUpdate;
    // @dev Pending amount
    uint256 pending;
}

// NOTE: Must be removed before merging
interface IPoolRegistryExtended {
    function getPoolDenomination(PoolId poolId) external view returns (uint256 poolDenomination);
}

// Assumptions:
// * ShareClassId is unique and derived from pool, i.e. bytes16(keccak256(poolId + salt))
contract SingleShareClass is Auth, IShareClassManager {
    using MathLib for uint128;
    using MathLib for uint256;

    /// Storage
    uint32 private /*TODO: transient*/ _epochIncrement;
    address public immutable poolRegistry;
    mapping(bytes16 => mapping(address assetId => bool)) public allowedAssets;
    mapping(bytes16 => mapping(address assetId => mapping(address investor => UserOrder pending))) public
        depositRequests;
    mapping(bytes16 => mapping(address assetId => mapping(address investor => UserOrder pending))) public redeemRequests;
    mapping(bytes16 => mapping(address assetId => uint256 pending)) public pendingDeposits;
    // TODO(@review): Check whether needed for accounting. If not, remove
    mapping(bytes16 => uint256 approved) public approvedDeposits;
    mapping(bytes16 => uint256 nav) public shareClassNav;
    mapping(bytes16 => mapping(uint32 epochId => Epoch epoch)) public epochRatios;
    mapping(PoolId poolId => uint32 epochId) public epochs;
    mapping(PoolId poolId => bytes16) public shareClassIds;
    mapping(bytes16 => uint256) totalIssuance;
    mapping(bytes16 => uint32 epochId) latestIssuance;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) latestDepositApproval;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) latestRedeemApproval;

    /// Errors
    error NegativeNav();

    constructor(address deployer, address poolRegistry_) Auth(deployer) {
        require(poolRegistry != address(0), "Empty poolRegistry");
        poolRegistry = poolRegistry_;
    }

    /// @inheritdoc IShareClassManager
    function allowAsset(PoolId poolId, bytes16 shareClassId, address assetId) external auth {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        allowedAssets[shareClassId][assetId] = true;

        emit IShareClassManager.AllowedAsset(poolId, shareClassId, assetId);
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(
        PoolId poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address depositAssetId
    ) external {
        require(allowedAssets[shareClassId][depositAssetId] == true, IShareClassManager.AssetNotAllowed());

        _updateDepositRequest(poolId, shareClassId, int256(amount), investor, depositAssetId);
    }

    function cancelDepositRequest(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
    {
        _updateDepositRequest(
            poolId,
            shareClassId,
            -int256(depositRequests[shareClassId][depositAssetId][investor].pending),
            investor,
            depositAssetId
        );
    }

    /// @inheritdoc IShareClassManager
    function requestRedeem(PoolId poolId, bytes16 shareClassId, uint256 amount, address investor, address payoutAssetId)
        external
    {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function cancelRedeemRequest(PoolId poolId, bytes16 shareClassId, address investor, address payoutAssetId)
        external
    {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function approveDeposits(
        PoolId poolId,
        bytes16 shareClassId,
        uint128 approvalRatio,
        address paymentAssetId,
        uint128 paymentAssetPrice
    ) external auth returns (uint256 approvedPoolAmount, uint256 approvedAssetAmount) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        // Reduce pendingDeposits
        uint256 pendingDeposit = pendingDeposits[shareClassId][paymentAssetId];
        approvedAssetAmount = d18(approvalRatio).mulUint256(pendingDeposit);
        pendingDeposits[shareClassId][paymentAssetId] -= approvedAssetAmount;

        // Increase approvedDeposits
        approvedPoolAmount = d18(paymentAssetPrice).mulUint256(approvedAssetAmount);
        approvedDeposits[shareClassId] += approvedPoolAmount;

        // Store ratios in epochRatios and advance epochId
        uint32 epochId = epochs[poolId];
        epochs[poolId] = _incrementEpoch(epochId);

        // Due to advancing the epoch post-approval, redemption ratio is zero for this epoch
        // ShareClass price is set during issuance
        epochRatios[shareClassId][epochId] =
            Epoch(d18(0), d18(approvalRatio), d18(paymentAssetPrice), d18(0), approvedPoolAmount);
        latestDepositApproval[shareClassId][paymentAssetId] = epochId;

        emit IShareClassManager.NewEpoch(poolId, epochId + 1);
        emit IShareClassManager.ApprovedDeposits(
            poolId,
            shareClassId,
            epochId,
            paymentAssetId,
            approvalRatio,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingDeposit,
            paymentAssetPrice
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedemptions(
        PoolId poolId,
        bytes16 shareClassId,
        uint128 approvalRatio,
        address payoutAssetId,
        uint128 payoutAssetPrice
    ) external auth returns (uint256 approved, uint256 pending) {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, bytes16 shareClassId, uint256 nav) external auth {
        this.issueSharesUntilEpoch(poolId, shareClassId, nav, epochs[poolId] - 1);
    }

    /// @notice Emits new shares for the given identifier based on the provided NAV up to the desired epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param nav Total value of assets of the pool and share class
    /// @param endEpochId Identifier of the maximum epoch until which shares are issued
    function issueSharesUntilEpoch(PoolId poolId, bytes16 shareClassId, uint256 nav, uint32 endEpochId) external auth {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(endEpochId < epochs[poolId], IShareClassManager.EpochNotFound(epochs[poolId]));

        uint32 startEpochId = latestIssuance[shareClassId];
        uint256 poolDenomination = IPoolRegistryExtended(poolRegistry).getPoolDenomination(poolId);

        for (uint32 epochId = startEpochId; epochId <= endEpochId; epochId++) {
            uint256 newShares = _issueEpochShares(shareClassId, nav, poolDenomination, epochId);

            emit IShareClassManager.IssuedShares(poolId, shareClassId, epochId, nav, newShares);
        }

        latestIssuance[shareClassId] = endEpochId;
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, bytes16 shareClassId, uint256 nav) external auth {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payout, uint256 payment)
    {
        return this.claimDepositUntilEpoch(poolId, shareClassId, investor, depositAssetId, latestIssuance[shareClassId]);
    }

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued until the provided epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient address of the share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payout Amount of shares which the investor receives
    /// @return payment Amount of deposit asset which was taken as payment
    function claimDepositUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address depositAssetId,
        uint32 endEpochId
    ) external returns (uint256 payout, uint256 payment) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(endEpochId < epochs[poolId], IShareClassManager.EpochNotFound(epochs[poolId]));

        UserOrder storage userOrder = depositRequests[shareClassId][depositAssetId][investor];

        for (uint32 epochId = userOrder.lastUpdate; epochId <= endEpochId; epochId++) {
            (uint256 approvedAssetAmount, uint256 pendingAssetAmount, uint256 investorShares) =
                _claimEpochDeposit(shareClassId, userOrder, epochId);
            payout += investorShares;
            payment += approvedAssetAmount;

            emit IShareClassManager.ClaimedDeposit(
                poolId,
                shareClassId,
                epochId,
                investor,
                depositAssetId,
                approvedAssetAmount,
                pendingAssetAmount,
                investorShares
            );
        }

        userOrder.lastUpdate = endEpochId;
    }

    /// @inheritdoc IShareClassManager
    function claimRedeem(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payout)
    {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function updateShareClassNav(PoolId poolId, bytes16 shareClassId, int256 navCorrection)
        external
        auth
        returns (uint256 nav)
    {
        require(navCorrection >= 0, NegativeNav());
        return this.updateShareClassNav(poolId, shareClassId, uint256(navCorrection));
    }

    function updateShareClassNav(PoolId poolId, bytes16 shareClassId, uint256 nav) external auth returns (uint256) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        shareClassNav[shareClassId] = nav;
        emit IShareClassManager.UpdatedNav(poolId, shareClassId, nav);

        return nav;
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId, /*poolId*/ bytes memory /*_data*/ ) external pure returns (bytes16) {
        revert IShareClassManager.MaxShareClassNumberExceeded(1);
    }

    /// @inheritdoc IShareClassManager
    function isAllowedAsset(PoolId poolId, bytes16 shareClassId, address assetId) external view returns (bool) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        return allowedAssets[shareClassId][assetId];
    }

    /// @inheritdoc IShareClassManager
    function getShareClassNav(PoolId poolId, bytes16 shareClassId) external view returns (uint256 nav) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        return shareClassNav[shareClassId];
    }

    /// @notice Emits new shares for the given identifier based on the provided NAV for the desired epoch.
    ///
    /// @param shareClassId Identifier of the share class
    /// @param nav Total value of assets of the pool and share class
    /// @param epochId Identifier of the epoch for which shares are issued
    function _issueEpochShares(bytes16 shareClassId, uint256 nav, uint256 poolDenomination, uint32 epochId)
        private
        returns (uint256 newShares)
    {
        D18 shareToPoolQuote = d18((nav.mulDiv(1e18, poolDenomination) / totalIssuance[shareClassId]).toUint128());
        newShares = shareToPoolQuote.mulUint256(epochRatios[shareClassId][epochId].approvedDeposits);

        epochRatios[shareClassId][epochId].shareClassToAssetQuote =
            shareToPoolQuote / epochRatios[shareClassId][epochId].assetToPoolQuote;
        totalIssuance[shareClassId] += newShares;
    }

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued until the provided epoch.
    ///
    /// @param shareClassId Identifier of the share class
    /// @param userOrder Pending order of the investor
    /// @param epochId Identifier of the  epoch for which it is claimed
    /// @return approvedAssetAmount Amount of deposit asset which was approved and taken as payment
    /// @return pendingAssetAmount Amount of deposit asset which was is pending for approval
    /// @return investorShares Amount of shares which the investor receives
    function _claimEpochDeposit(bytes16 shareClassId, UserOrder storage userOrder, uint32 epochId)
        private
        returns (uint256 approvedAssetAmount, uint256 pendingAssetAmount, uint256 investorShares)
    {
        Epoch memory epoch = epochRatios[shareClassId][epochId];
        approvedAssetAmount = epoch.depositRatio.mulUint256(userOrder.pending);
        investorShares = epochRatios[shareClassId][epochId].shareClassToAssetQuote.mulUint256(approvedAssetAmount);

        userOrder.pending -= approvedAssetAmount;

        return (approvedAssetAmount, userOrder.pending, investorShares);
    }

    /// @notice Increments the given epoch id if it has not been incremented within the current block. If the epoch has
    /// already been bumped, we don't bump it again to allow deposit and redeem approvals to point to the same epoch id.
    ///
    /// @param epochId Identifier of the epoch which we want to increment.
    /// @return incrementedEpochId Potentially incremented epoch identifier.
    function _incrementEpoch(uint32 epochId) private returns (uint32 incrementedEpochId) {
        if (_epochIncrement == 0) {
            _epochIncrement = 1;
        }
        return epochId + _epochIncrement;
    }

    /// @notice Updates the amount of a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Asset token amount which is updated
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function _updateDepositRequest(
        PoolId poolId,
        bytes16 shareClassId,
        int256 amount,
        address investor,
        address depositAssetId
    ) private {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        // TODO: Permission check for investor

        UserOrder storage userOrder = depositRequests[shareClassId][depositAssetId][investor];
        uint32 latestDepositApproval_ = latestDepositApproval[shareClassId][depositAssetId];
        require(
            latestDepositApproval_ == 0 || userOrder.lastUpdate > latestDepositApproval_,
            IShareClassManager.ClaimDepositRequired()
        );

        userOrder.lastUpdate = epochs[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint256(amount) : userOrder.pending - uint256(amount);

        pendingDeposits[shareClassId][depositAssetId] = amount >= 0
            ? pendingDeposits[shareClassId][depositAssetId] + uint256(amount)
            : pendingDeposits[shareClassId][depositAssetId] - uint256(amount);

        emit IShareClassManager.UpdatedDepositRequest(
            poolId,
            shareClassId,
            epochs[poolId],
            investor,
            userOrder.pending,
            pendingDeposits[shareClassId][depositAssetId],
            depositAssetId
        );
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {D18, d18} from "src/types/D18.sol";

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
    uint32 lastEpochIdOrdered;
    // @dev Amount of pending deposit request in asset denomination
    uint256 pendingDepositRequest;
    // @dev Amount of pending redeem request in share class denomination
    uint256 pendingRedeemRequest;
}

// NOTE: Must be removed before merging
interface IPoolRegistry {
    function getPoolDenomination(uint64 poolId) external view returns (uint256 poolDenomination);
}

// Assumptions:
// * ShareClassId is unique and derived from pool, i.e. bytes16(keccak256(poolId + salt))
contract SingleShareClass is IShareClassManager {
    using MathLib for uint128;
    using MathLib for uint256;

    /// Storage
    address public immutable poolRegistry;
    mapping(bytes16 => mapping(address assetId => bool)) public allowedAssets;
    mapping(bytes16 => mapping(address assetId => mapping(address investor => UserOrder pending))) public userOrders;
    mapping(bytes16 => mapping(address assetId => uint256 pending)) public pendingDeposits;
    // TODO(@review): Check whether needed for accounting. If not, remove
    mapping(bytes16 => uint256 approved) public approvedDeposits;
    mapping(bytes16 => uint256 nav) public shareClassNav;
    // TOOD(@wischli): Check whether per epochId is necessary
    mapping(bytes16 => mapping(uint32 epochId => Epoch epoch)) public epochRatios;
    mapping(uint64 poolId => uint32 epochId) public epochs;
    mapping(uint64 poolId => bytes16) public shareClassIds;
    mapping(bytes16 => uint256) totalIssuance;
    mapping(bytes16 => uint32 epochId) latestIssuance;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) latestDepositApproval;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) latestRedemptionApproval;

    /// Errors
    error NegativeNav();

    constructor(address poolRegistry_) {
        require(poolRegistry != address(0), "Empty poolRegistry");
        poolRegistry = poolRegistry_;
    }

    /// @inheritdoc IShareClassManager
    function allowAsset(uint64 poolId, bytes16 shareClassId, address assetId) public {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));

        allowedAssets[shareClassId][assetId] = true;

        emit IShareClassManager.AllowedAsset(poolId, shareClassId, assetId);
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address depositAssetId
    ) public {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));
        require(
            allowedAssets[shareClassId][depositAssetId] == true,
            IShareClassManager.AssetNotAllowed(poolId, shareClassId, depositAssetId)
        );
        // TODO: Permission check for investor or rely on PoolManager to check this?

        UserOrder storage userOrder = userOrders[shareClassId][depositAssetId][investor];
        require(
            userOrder.lastEpochIdOrdered > latestDepositApproval[shareClassId][depositAssetId],
            IShareClassManager.ClaimDepositRequired(poolId, shareClassId, depositAssetId, investor)
        );

        userOrder.lastEpochIdOrdered = epochs[poolId];
        userOrder.pendingDepositRequest += amount;
        pendingDeposits[shareClassId][depositAssetId] += amount;

        emit IShareClassManager.UpdatedDepositRequest(
            poolId,
            shareClassId,
            epochs[poolId],
            investor,
            userOrder.pendingDepositRequest - amount,
            userOrder.pendingDepositRequest,
            depositAssetId
        );
    }

    /// @inheritdoc IShareClassManager
    function requestRedemption(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address payoutAssetId
    ) public {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function approveDeposits(
        uint64 poolId,
        bytes16 shareClassId,
        uint128 approvalRatio,
        address paymentAssetId,
        uint128 paymentAssetPrice
    ) public returns (uint256 approvedPoolAmount, uint256 approvedAssetAmount) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));
        require(
            allowedAssets[shareClassId][paymentAssetId] == true,
            IShareClassManager.AssetNotAllowed(poolId, shareClassId, paymentAssetId)
        );

        // Reduce pendingDeposits
        uint256 pendingDeposit = pendingDeposits[shareClassId][paymentAssetId];
        approvedAssetAmount = d18(approvalRatio).mulUint256(pendingDeposit);
        pendingDeposit -= approvedAssetAmount;

        // Increase approvedDeposits
        approvedPoolAmount = d18(paymentAssetPrice).mulUint256(approvedAssetAmount);
        approvedDeposits[shareClassId] += approvedPoolAmount;

        // Store ratios in epochRatios and advance epochId
        uint32 epochId = epochs[poolId]++;
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
        uint64 poolId,
        bytes16 shareClassId,
        uint128 approvalRatio,
        address payoutAssetId,
        uint128 payoutAssetPrice
    ) public returns (uint256 approved, uint256 pending) {
        // TODO(@wischli)
    }

    function issueShares(uint64 poolId, bytes16 shareClassId, uint256 nav) public {
        this.issueEpochShares(poolId, shareClassId, nav, epochs[poolId] - 1);
    }

    // TODO(@wischli): Docs
    function issueEpochShares(uint64 poolId, bytes16 shareClassId, uint256 nav, uint32 endEpochId) public {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));
        require(endEpochId <= epochs[poolId], IShareClassManager.EpochNotFound(poolId, endEpochId));

        uint32 startEpochId = latestIssuance[shareClassId];
        uint256 poolDenomination = IPoolRegistry(poolRegistry).getPoolDenomination(poolId);

        for (uint32 epochId = startEpochId; epochId <= endEpochId; epochId++) {
            uint256 newShares = _issueEpochShares(shareClassId, nav, poolDenomination, epochId);

            emit IShareClassManager.IssuedShares(poolId, shareClassId, epochId, nav, newShares);
        }

        latestIssuance[shareClassId] = endEpochId;
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(uint64 poolId, bytes16 shareClassId, uint256 nav) public {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(uint64 poolId, bytes16 shareClassId, address investor, address depositAssetId)
        public
        returns (uint256 payout)
    {
        return this.claimEpochDeposit(poolId, shareClassId, investor, depositAssetId, latestIssuance[shareClassId]);
    }

    // TODO(@wischli): Docs
    function claimEpochDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address investor,
        address depositAssetId,
        uint32 endEpochId
    ) public returns (uint256 payout) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));
        require(endEpochId <= epochs[poolId], IShareClassManager.EpochNotFound(poolId, endEpochId));
        require(
            allowedAssets[shareClassId][depositAssetId] == true,
            IShareClassManager.AssetNotAllowed(poolId, shareClassId, depositAssetId)
        );

        UserOrder storage userOrder = userOrders[shareClassId][depositAssetId][investor];

        for (uint32 epochId = userOrder.lastEpochIdOrdered; epochId <= endEpochId; epochId++) {
            (uint256 approvedAssetAmount, uint256 pendingAssetAmount, uint256 investorShares) =
                _claimEpochDeposit(shareClassId, userOrder, epochId);
            payout += investorShares;

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

        userOrder.lastEpochIdOrdered = endEpochId;
    }

    /// @inheritdoc IShareClassManager
    function claimRedemption(uint64 poolId, bytes16 shareClassId, address investor, address depositAssetId)
        public
        returns (uint256 payout)
    {
        // TODO(@wischli)
    }

    /// @inheritdoc IShareClassManager
    function updateShareClassNav(uint64 poolId, bytes16 shareClassId, int256 navCorrection)
        public
        returns (uint256 nav)
    {
        require(navCorrection >= 0, NegativeNav());
        return this.updateShareClassNav(poolId, shareClassId, uint256(navCorrection));
    }

    function updateShareClassNav(uint64 poolId, bytes16 shareClassId, uint256 nav) public returns (uint256) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));

        shareClassNav[shareClassId] = nav;
        emit IShareClassManager.UpdatedNav(poolId, shareClassId, nav);

        return nav;
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(uint64 poolId, bytes memory /*_data*/ ) public pure returns (bytes16) {
        revert IShareClassManager.MaxShareClassNumberExceeded(poolId, 1);
    }

    /// @inheritdoc IShareClassManager
    function isAllowedAsset(uint64 poolId, bytes16 shareClassId, address assetId) public view returns (bool) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));

        return allowedAssets[shareClassId][assetId];
    }

    /// @inheritdoc IShareClassManager
    function getShareClassNav(uint64 poolId, bytes16 shareClassId) public view returns (uint256 nav) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(poolId, shareClassId));

        return shareClassNav[shareClassId];
    }

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

    function _claimEpochDeposit(bytes16 shareClassId, UserOrder storage userOrder, uint32 epochId)
        private
        returns (uint256 approvedAssetAmount, uint256 pendingAssetAmount, uint256 investorShares)
    {
        Epoch memory epoch = epochRatios[shareClassId][epochId];
        approvedAssetAmount = epoch.depositRatio.mulUint256(userOrder.pendingDepositRequest);
        investorShares = epochRatios[shareClassId][epochId].shareClassToAssetQuote.mulUint256(approvedAssetAmount);

        userOrder.pendingDepositRequest -= approvedAssetAmount;

        return (approvedAssetAmount, userOrder.pendingDepositRequest, investorShares);
    }
}

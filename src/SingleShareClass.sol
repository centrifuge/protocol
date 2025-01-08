// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {Auth} from "src/Auth.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {D18, d18} from "src/types/D18.sol";
import {PoolId} from "src/types/PoolId.sol";
import {IERC7726Ext} from "src/interfaces/IERC7726.sol";
import {IInvestorPermissions} from "src/interfaces/IInvestorPermissions.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";

struct Epoch {
    /// @dev Valuation used for quotas
    IERC7726Ext valuation;
    /// @dev Amount of approved deposits (in pool denomination)
    uint256 approvedDeposits;
    /// @dev Amount of approved shares (in share denomination)
    uint256 approvedShares;
}

struct EpochRatio {
    /// @dev Percentage of approved redemptions
    D18 redeemRatio;
    /// @dev Percentage of approved deposits
    D18 depositRatio;
    /// @dev Price of one pool currency per asset
    D18 assetToPoolQuote;
    /// @dev Price of one share class per pool token
    D18 poolToShareQuote;
}

struct UserOrder {
    /// @dev Pending amount
    uint256 pending;
    /// @dev Index of epoch in which last order was made
    uint32 lastUpdate;
}

// Assumptions:
// * ShareClassId is unique and derived from pool, i.e. bytes16(keccak256(poolId + salt))
contract SingleShareClass is Auth, IShareClassManager {
    using MathLib for D18;
    using MathLib for uint256;

    /// Storage
    // TODO: Reorder for optimal storage layout
    // uint32 private transient _epochIncrement;
    uint32 private /*transient*/ _epochIncrement;
    address public immutable poolRegistry;
    address public immutable investorPermissions;
    mapping(PoolId poolId => bytes16) public shareClassIds;
    // User storage
    mapping(bytes16 => mapping(address paymentAssetId => mapping(address investor => UserOrder pending))) public
        depositRequests;
    mapping(bytes16 => mapping(address payoutAssetId => mapping(address investor => UserOrder pending))) public
        redeemRequests;
    // Share class storage
    mapping(bytes16 => mapping(address assetId => bool)) public allowedAssets;
    mapping(bytes16 => mapping(address paymentAssetId => uint256 pending)) public pendingDeposits;
    mapping(bytes16 => mapping(address payoutAssetId => uint256 pending)) public pendingRedeems;
    mapping(bytes16 => D18 navPerShare) public shareClassNavPerShare;
    mapping(bytes16 => uint256) public totalIssuance;
    // Share class + epoch storage
    mapping(PoolId poolId => uint32 epochId) public epochIds;
    mapping(bytes16 => mapping(uint32 epochId => Epoch epoch)) public epochs;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) latestDepositApproval;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) latestRedeemApproval;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) public latestIssuance;
    mapping(bytes16 => mapping(address assetId => uint32 epochId)) public latestRevocation;
    mapping(bytes16 => mapping(address assetId => mapping(uint32 epochId => EpochRatio epoch))) public epochRatios;

    /// Errors
    error Unauthorized();
    error ShareClassIdAlreadySet();
    error NotYetApproved();

    constructor(address deployer, address poolRegistry_, address investorPermissions_) Auth(deployer) {
        require(poolRegistry_ != address(0), "Empty poolRegistry");
        require(investorPermissions_ != address(0), "Empty investorPermissions");
        poolRegistry = poolRegistry_;
        investorPermissions = investorPermissions_;
    }

    // TODO(@wischli): Docs
    function setShareClassId(PoolId poolId, bytes16 shareClassId_) external auth {
        require(shareClassIds[poolId] == bytes16(0), ShareClassIdAlreadySet());

        shareClassIds[poolId] = shareClassId_;
        epochIds[poolId] = 1;
    }

    /// @inheritdoc IShareClassManager
    function allowAsset(PoolId poolId, bytes16 shareClassId, address assetId) external auth {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        allowedAssets[shareClassId][assetId] = true;

        emit IShareClassManager.AllowedAsset(poolId, shareClassId, assetId);
    }

    /// @inheritdoc IShareClassManager
    function disallowAsset(PoolId poolId, bytes16 shareClassId, address assetId) external auth {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        delete allowedAssets[shareClassId][assetId];

        emit IShareClassManager.DisallowedAsset(poolId, shareClassId, assetId);
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(
        PoolId poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address depositAssetId
    ) external {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(allowedAssets[shareClassId][depositAssetId] == true, IShareClassManager.AssetNotAllowed());

        _updateDepositRequest(poolId, shareClassId, int256(amount), investor, depositAssetId);
    }

    function cancelDepositRequest(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
    {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

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
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(allowedAssets[shareClassId][payoutAssetId] == true, IShareClassManager.AssetNotAllowed());

        _updateRedeemRequest(poolId, shareClassId, int256(amount), investor, payoutAssetId);
    }

    /// @inheritdoc IShareClassManager
    function cancelRedeemRequest(PoolId poolId, bytes16 shareClassId, address investor, address payoutAssetId)
        external
    {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        _updateRedeemRequest(
            poolId,
            shareClassId,
            -int256(redeemRequests[shareClassId][payoutAssetId][investor].pending),
            investor,
            payoutAssetId
        );
    }

    /// @inheritdoc IShareClassManager
    function approveDeposits(
        PoolId poolId,
        bytes16 shareClassId,
        D18 approvalRatio,
        address paymentAssetId,
        IERC7726Ext valuation
    ) external auth returns (uint256 approvedPoolAmount, uint256 approvedAssetAmount) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Reduce pending
        approvedAssetAmount = approvalRatio.mulUint256(pendingDeposits[shareClassId][paymentAssetId]);
        pendingDeposits[shareClassId][paymentAssetId] -= approvedAssetAmount;
        uint256 pendingDepositsPostUpdate = pendingDeposits[shareClassId][paymentAssetId];

        // Increase approved
        address poolCurrency = address(IPoolRegistry(poolRegistry).currency(poolId));
        D18 paymentAssetPrice = d18(valuation.getFactor(paymentAssetId, poolCurrency).toUint128());
        approvedPoolAmount = paymentAssetPrice.mulUint256(approvedAssetAmount);

        // Update epoch data
        Epoch storage epoch = epochs[shareClassId][approvalEpochId];
        epoch.valuation = valuation;
        epoch.approvedDeposits += approvedPoolAmount;

        EpochRatio storage epochRatio = epochRatios[shareClassId][paymentAssetId][approvalEpochId];
        epochRatio.depositRatio = approvalRatio;
        epochRatio.assetToPoolQuote = paymentAssetPrice;

        latestDepositApproval[shareClassId][paymentAssetId] = approvalEpochId;

        emit IShareClassManager.ApprovedDeposits(
            poolId,
            shareClassId,
            approvalEpochId,
            paymentAssetId,
            approvalRatio,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingDepositsPostUpdate,
            paymentAssetPrice
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(
        PoolId poolId,
        bytes16 shareClassId,
        D18 approvalRatio,
        address payoutAssetId,
        IERC7726Ext valuation
    ) external auth returns (uint256 approvedShares, uint256 pendingShares) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Reduce pending
        approvedShares = approvalRatio.mulUint256(pendingRedeems[shareClassId][payoutAssetId]);
        pendingRedeems[shareClassId][payoutAssetId] -= approvedShares;
        pendingShares = pendingRedeems[shareClassId][payoutAssetId];

        // Increase approved
        address poolCurrency = address(IPoolRegistry(poolRegistry).currency(poolId));
        D18 assetToPool = d18(valuation.getFactor(payoutAssetId, poolCurrency).toUint128());

        // Update epoch data
        Epoch storage epoch = epochs[shareClassId][approvalEpochId];
        epoch.valuation = valuation;
        epoch.approvedShares += approvedShares;

        EpochRatio storage epochRatio = epochRatios[shareClassId][payoutAssetId][approvalEpochId];
        epochRatio.redeemRatio = approvalRatio;
        epochRatio.assetToPoolQuote = assetToPool;

        latestRedeemApproval[shareClassId][payoutAssetId] = approvalEpochId;

        emit IShareClassManager.ApprovedRedeems(
            poolId,
            shareClassId,
            approvalEpochId,
            payoutAssetId,
            approvalRatio,
            approvedShares,
            pendingShares,
            assetToPool
        );
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, bytes16 shareClassId, address depositAssetId, D18 navPerShare) external auth {
        uint32 latestApproval_ = latestDepositApproval[shareClassId][depositAssetId];
        require(latestApproval_ > 0, NotYetApproved());

        issueSharesUntilEpoch(poolId, shareClassId, depositAssetId, navPerShare, latestApproval_);
    }

    /// @notice Emits new shares for the given identifier based on the provided NAV up to the desired epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param endEpochId Identifier of the maximum epoch until which shares are issued
    function issueSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(endEpochId < epochIds[poolId], IShareClassManager.EpochNotFound());

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = latestIssuance[shareClassId][depositAssetId] + 1;

        for (uint32 epochId = startEpochId; epochId <= endEpochId; epochId++) {
            uint256 newShares = _issueEpochShares(shareClassId, depositAssetId, navPerShare, epochId);
            uint256 nav = navPerShare.mulUint256(newShares);

            emit IShareClassManager.IssuedShares(poolId, shareClassId, epochId, navPerShare, nav, newShares);
        }

        latestIssuance[shareClassId][depositAssetId] = endEpochId;
        shareClassNavPerShare[shareClassId] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, bytes16 shareClassId, address payoutAssetId, D18 navPerShare)
        external
        auth
        returns (uint256 payoutAssetAmount, uint256 payoutPoolAmount)
    {
        uint32 latestApproval_ = latestRedeemApproval[shareClassId][payoutAssetId];
        require(latestApproval_ > 0, NotYetApproved());

        return revokeSharesUntilEpoch(poolId, shareClassId, payoutAssetId, navPerShare, latestApproval_);
    }

    /// @notice Revokes shares for an epoch span and sets the price based on amount of approved redemption shares and
    /// the
    /// provided NAV.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param endEpochId Identifier of the maximum epoch until which shares are revoked
    /// @return payoutAssetAmount Converted amount of payout asset based on number of revoked shares
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function revokeSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address payoutAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth returns (uint256 payoutAssetAmount, uint256 payoutPoolAmount) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(endEpochId < epochIds[poolId], IShareClassManager.EpochNotFound());

        uint256 totalRevokedShares = 0;

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = latestRevocation[shareClassId][payoutAssetId] + 1;

        for (uint32 epochId = startEpochId; epochId <= endEpochId; epochId++) {
            (uint256 revokedShares, uint256 epochPoolAmount) =
                _revokeEpochShares(shareClassId, payoutAssetId, navPerShare, epochId);
            payoutPoolAmount += epochPoolAmount;

            payoutAssetAmount +=
                epochRatios[shareClassId][payoutAssetId][epochId].assetToPoolQuote.reciprocalMulInt(epochPoolAmount);
            uint256 nav = navPerShare.mulUint256(revokedShares);
            totalRevokedShares += revokedShares;

            emit IShareClassManager.RevokedShares(poolId, shareClassId, epochId, navPerShare, nav, revokedShares);
        }

        totalIssuance[shareClassId] -= totalRevokedShares;
        latestRevocation[shareClassId][payoutAssetId] = endEpochId;
        shareClassNavPerShare[shareClassId] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payoutShareAmount, uint256 paymentAssetAmount)
    {
        return claimDepositUntilEpoch(
            poolId, shareClassId, investor, depositAssetId, latestIssuance[shareClassId][depositAssetId]
        );
    }

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued until the provided epoch.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient of the share class tokens
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payoutShareAmount Amount of shares which the investor receives
    /// @return paymentAssetAmount Amount of deposit asset which was taken as payment
    function claimDepositUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address depositAssetId,
        uint32 endEpochId
    ) public returns (uint256 payoutShareAmount, uint256 paymentAssetAmount) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(endEpochId < epochIds[poolId], IShareClassManager.EpochNotFound());

        UserOrder storage userOrder = depositRequests[shareClassId][depositAssetId][investor];

        for (uint32 epochId = userOrder.lastUpdate; epochId <= endEpochId; epochId++) {
            (uint256 approvedAssetAmount, uint256 pendingAssetAmount, uint256 investorShares) =
                _claimEpochDeposit(shareClassId, depositAssetId, userOrder, epochId);
            payoutShareAmount += investorShares;
            paymentAssetAmount += approvedAssetAmount;

            userOrder.pending = pendingAssetAmount;

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

        userOrder.lastUpdate = endEpochId + 1;
    }

    /// @inheritdoc IShareClassManager
    function claimRedeem(PoolId poolId, bytes16 shareClassId, address investor, address payoutAssetId)
        external
        returns (uint256 payoutAssetAmount, uint256 paymentShareAmount)
    {
        return claimRedeemUntilEpoch(
            poolId, shareClassId, investor, payoutAssetId, latestRevocation[shareClassId][payoutAssetId]
        );
    }

    /// @notice Reduces the share class token count of the investor in exchange for collecting an amount of payment
    /// asset for the specified range of epochs.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param investor Address of the recipient of the payout asset
    /// @param payoutAssetId Identifier of the asset which the investor committed to as payout when requesting the
    /// redemption
    /// @param endEpochId Identifier of the maximum epoch until it is claimed claim
    /// @return payoutAssetAmount Amount of payout asset which the investor receives
    /// @return paymentShareAmount Amount of shares which the investor redeemed
    function claimRedeemUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address payoutAssetId,
        uint32 endEpochId
    ) public returns (uint256 payoutAssetAmount, uint256 paymentShareAmount) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));
        require(endEpochId < epochIds[poolId], IShareClassManager.EpochNotFound());

        UserOrder storage userOrder = redeemRequests[shareClassId][payoutAssetId][investor];

        for (uint32 epochId = userOrder.lastUpdate; epochId <= endEpochId; epochId++) {
            (uint256 approvedShares, uint256 approvedAssetAmount) =
                _claimEpochRedeem(shareClassId, payoutAssetId, userOrder, epochId);

            paymentShareAmount += approvedShares;
            payoutAssetAmount += approvedAssetAmount;

            userOrder.pending -= approvedShares;

            emit IShareClassManager.ClaimedRedeem(
                poolId,
                shareClassId,
                epochId,
                investor,
                payoutAssetId,
                approvedShares,
                userOrder.pending,
                approvedAssetAmount
            );
        }

        userOrder.lastUpdate = endEpochId + 1;
    }

    /// @inheritdoc IShareClassManager
    function updateShareClassNav(PoolId poolId, bytes16 shareClassId) external view returns (D18, uint256) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        // TODO(@mustermeiszer): Needed for single share class?
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function update(PoolId, bytes calldata) external pure {
        // TODO(@mustermeiszer): Needed for single share class?
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId, bytes calldata) external pure returns (bytes16) {
        revert IShareClassManager.MaxShareClassNumberExceeded(1);
    }

    /// @inheritdoc IShareClassManager
    function isAllowedAsset(PoolId poolId, bytes16 shareClassId, address assetId) external view returns (bool) {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        return allowedAssets[shareClassId][assetId];
    }

    /// @inheritdoc IShareClassManager
    // TODO(@mustermeiszer): Needed for single share class?
    function getShareClassNavPerShare(PoolId poolId, bytes16 shareClassId)
        external
        view
        returns (D18 navPerShare, uint256 issuance)
    {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassMismatch(shareClassIds[poolId]));

        return (shareClassNavPerShare[shareClassId], totalIssuance[shareClassId]);
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
        require(IInvestorPermissions(investorPermissions).isUnfrozenInvestor(shareClassId, investor), Unauthorized());

        UserOrder storage userOrder = depositRequests[shareClassId][depositAssetId][investor];

        // Block updates until pending amount does not impact claimable amount, i.e. last update happened after latest
        // approval
        uint32 latestApproval = latestDepositApproval[shareClassId][depositAssetId];
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            IShareClassManager.ClaimDepositRequired()
        );

        userOrder.lastUpdate = epochIds[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint256(amount) : userOrder.pending - uint256(-amount);

        pendingDeposits[shareClassId][depositAssetId] = amount >= 0
            ? pendingDeposits[shareClassId][depositAssetId] + uint256(amount)
            : pendingDeposits[shareClassId][depositAssetId] - uint256(-amount);

        emit IShareClassManager.UpdatedDepositRequest(
            poolId,
            shareClassId,
            epochIds[poolId],
            investor,
            depositAssetId,
            userOrder.pending,
            pendingDeposits[shareClassId][depositAssetId]
        );
    }

    // TODO(@wischli): Docs
    function _updateRedeemRequest(
        PoolId poolId,
        bytes16 shareClassId,
        int256 amount,
        address investor,
        address payoutAssetId
    ) private {
        require(IInvestorPermissions(investorPermissions).isUnfrozenInvestor(shareClassId, investor), Unauthorized());

        UserOrder storage userOrder = redeemRequests[shareClassId][payoutAssetId][investor];

        // Block updates until pending amount does not impact claimable amount
        uint32 latestApproval = latestRedeemApproval[shareClassId][payoutAssetId];
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            IShareClassManager.ClaimRedeemRequired()
        );

        userOrder.lastUpdate = epochIds[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint256(amount) : userOrder.pending - uint256(-amount);

        pendingRedeems[shareClassId][payoutAssetId] = amount >= 0
            ? pendingRedeems[shareClassId][payoutAssetId] + uint256(amount)
            : pendingRedeems[shareClassId][payoutAssetId] - uint256(-amount);

        emit IShareClassManager.UpdatedRedeemRequest(
            poolId,
            shareClassId,
            epochIds[poolId],
            investor,
            payoutAssetId,
            userOrder.pending,
            pendingRedeems[shareClassId][payoutAssetId]
        );
    }

    /// @notice Emits new shares and sets price for the given identifier based on the provided NAV for the desired
    /// epoch.
    ///
    /// @param shareClassId Identifier of the share class
    /// @param depositAssetId Identifier of the deposit asset for which new shares are issued
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param epochId Identifier of the epoch for which shares are issued
    function _issueEpochShares(bytes16 shareClassId, address depositAssetId, D18 navPerShare, uint32 epochId)
        private
        returns (uint256 newShares)
    {
        // shares = navPerShare * approvedPoolAmount
        newShares = navPerShare.mulUint256(epochs[shareClassId][epochId].approvedDeposits);

        totalIssuance[shareClassId] += newShares;
        epochRatios[shareClassId][depositAssetId][epochId].poolToShareQuote = navPerShare;
    }

    /// @notice Revokes shares for an epoch and sets the price based on amount of approved redemption shares and the
    /// provided NAV.
    ///
    /// @param shareClassId Identifier of the share class
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param payoutAssetId Identifier of the payout asset for which shares are revoked
    /// @param epochId Identifier of the epoch for which shares are revoked
    /// @return revokedShares Amount of shares which were approved for revocation
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function _revokeEpochShares(bytes16 shareClassId, address payoutAssetId, D18 navPerShare, uint32 epochId)
        private
        returns (uint256 revokedShares, uint256 payoutPoolAmount)
    {
        revokedShares = epochs[shareClassId][epochId].approvedShares;

        // payout = shares / poolToShareQuote
        payoutPoolAmount = uint256(navPerShare.reciprocalMulInt(revokedShares));

        epochRatios[shareClassId][payoutAssetId][epochId].poolToShareQuote = navPerShare;
    }

    /// @notice Advances the current epoch of the given if it has not been incremented within the same block. If the
    /// epoch has already been incremented, we don't bump it again to allow deposit and redeem approvals to point to the
    /// same epoch id. Emits NewEpoch event if the epoch is advanced.
    ///
    /// @param poolId Identifier of the pool for which we want to advance an epoch.
    /// @return epochIdCurrentBlock Identifier of the current epoch. E.g., if the epoch advanced from i to i+1, i is
    /// returned.
    function _advanceEpoch(PoolId poolId) private returns (uint32 epochIdCurrentBlock) {
        uint32 epochId = epochIds[poolId];

        // Epoch doesn't necessarily advance, e.g. in case of multiple approvals inside the same multiCall
        if (_epochIncrement == 0) {
            _epochIncrement = 1;
            epochIds[poolId] += 1;

            emit IShareClassManager.NewEpoch(poolId, epochId + 1);

            return epochId;
        } else {
            return uint32(uint256(epochId - 1).max(1));
        }
    }

    /// @notice Collects shares for an investor after their deposit request was (partially) approved and new shares were
    /// issued until the provided epoch.
    ///
    /// @param shareClassId Identifier of the share class
    /// @param userOrder Pending order of the investor
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    /// @param epochId Identifier of the  epoch for which it is claimed
    /// @return approvedAssetAmount Amount of deposit asset which was approved and taken as payment
    /// @return pendingAssetAmount Amount of deposit asset which was is pending for approval
    /// @return investorShares Amount of shares which the investor receives
    function _claimEpochDeposit(
        bytes16 shareClassId,
        address depositAssetId,
        UserOrder storage userOrder,
        uint32 epochId
    ) private view returns (uint256 approvedAssetAmount, uint256 pendingAssetAmount, uint256 investorShares) {
        EpochRatio memory epochRatio = epochRatios[shareClassId][depositAssetId][epochId];

        approvedAssetAmount = epochRatio.depositRatio.mulUint256(userOrder.pending);

        // #shares = poolToShares * poolAmount  = poolToShare * (assetToPool * assetAmount)
        investorShares =
            epochRatio.poolToShareQuote.mulUint256(epochRatio.assetToPoolQuote.mulUint256(approvedAssetAmount));

        return (approvedAssetAmount, userOrder.pending - approvedAssetAmount, investorShares);
    }

    /// @notice Reduces the share class token count of the investor in exchange for collecting an amount of payment
    /// asset for the specified epoch.
    ///
    /// @param shareClassId Identifier of the share class
    /// @param userOrder Pending order of the investor
    /// @param payoutAssetId Identifier of the asset which the investor desires to receive
    /// @param epochId Identifier of the epoch for which it is claimed
    /// @return approvedShares Amount of shares which the investor redeemed
    /// @return approvedAssetAmount Amount of payout asset which the investor received
    function _claimEpochRedeem(bytes16 shareClassId, address payoutAssetId, UserOrder storage userOrder, uint32 epochId)
        private
        view
        returns (uint256 approvedShares, uint256 approvedAssetAmount)
    {
        EpochRatio memory epochRatio = epochRatios[shareClassId][payoutAssetId][epochId];

        approvedShares = epochRatio.redeemRatio.mulUint256(userOrder.pending);

        // assetAmount = poolAmount * poolToAsset = poolAmount / assetToPool = (#shares / poolToShare) / assetToPool
        approvedAssetAmount =
            epochRatio.assetToPoolQuote.reciprocalMulInt(epochRatio.poolToShareQuote.reciprocalMulInt(approvedShares));

        return (approvedShares, approvedAssetAmount);
    }
}

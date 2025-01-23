// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {D18, d18} from "src/types/D18.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC7726Ext} from "src/interfaces/IERC7726.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {ISingleShareClass} from "src/interfaces/ISingleShareClass.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PoolId} from "src/types/PoolId.sol";

struct Epoch {
    /// @dev Amount of approved deposits (in pool denomination)
    uint128 approvedDepositAmount;
    /// @dev Amount of approved shares (in share denomination)
    uint128 approvedShareAmount;
}

struct EpochRatio {
    uint128 approvedDepositAssetAmount;
    uint128 approvedDepositPoolAmount;
    /// @dev Percentage of approved redemptions
    D18 redeemRatio;
    /// @dev Price of one pool per asset token set during redeem approval
    D18 redeemAssetToPoolQuote;
    /// @dev Price of one pool per share class token set during deposit flow
    D18 depositShareToPoolQuote;
    /// @dev Price of one pool per share class token set during redeem flow
    D18 redeemShareToPoolQuote;
}

struct UserOrder {
    /// @dev Pending amount in deposit asset denomination
    uint128 pending;
    /// @dev Index of epoch in which last order was made
    uint32 lastUpdate;
}

struct AssetEpochState {
    /// @dev The last epoch in which a deposit approval was made
    uint32 latestDepositApproval;
    /// @dev The last epoch in which a redeem approval was made
    uint32 latestRedeemApproval;
    /// @dev The last epoch in which shares were issued
    uint32 latestIssuance;
    /// @dev The last epoch in which a shares were revoked
    uint32 latestRevocation;
}

// Assumptions:
// * ShareClassId is unique and derived from pool, i.e. bytes16(keccak256(poolId + salt))
contract SingleShareClass is Auth, ISingleShareClass {
    using MathLib for D18;
    using MathLib for uint128;

    /// Storage
    // uint32 private transient _epochIncrement;
    uint32 private /*transient*/ _epochIncrement;
    IPoolRegistry public poolRegistry;
    mapping(PoolId poolId => bytes16) public shareClassId;
    mapping(bytes16 scId => uint128) public totalIssuance;
    mapping(PoolId poolId => uint32 epochId_) public epochId;
    mapping(bytes16 scId => D18 navPerShare) private _shareClassNavPerShare;
    mapping(bytes16 scId => mapping(uint32 epochId_ => Epoch epoch)) public epoch;
    mapping(bytes16 scId => mapping(address assetId => AssetEpochState)) public assetEpochState;
    mapping(bytes16 scId => mapping(address payoutAssetId => uint128 pending)) public pendingRedeem;
    mapping(bytes16 scId => mapping(address paymentAssetId => uint128 pending)) public pendingDeposit;
    mapping(bytes16 scId => mapping(address assetId => mapping(uint32 epochId_ => EpochRatio epoch))) public epochRatio;
    mapping(bytes16 scId => mapping(address payoutAssetId => mapping(address investor => UserOrder pending))) public
        redeemRequest;
    mapping(bytes16 scId => mapping(address paymentAssetId => mapping(address investor => UserOrder pending))) public
        depositRequest;

    constructor(address poolRegistry_, address deployer) Auth(deployer) {
        poolRegistry = IPoolRegistry(poolRegistry_);
    }

    function file(bytes32 what, address data) external auth {
        require(what == "poolRegistry", ISingleShareClass.UnrecognizedFileParam());
        poolRegistry = IPoolRegistry(data);
        emit ISingleShareClass.File(what, data);
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId poolId, bytes calldata /* data */ ) external auth returns (bytes16 shareClassId_) {
        require(shareClassId[poolId] == bytes16(0), IShareClassManager.MaxShareClassNumberExceeded(1));

        shareClassId_ = bytes16(uint128(PoolId.unwrap(poolId)));

        shareClassId[poolId] = shareClassId_;
        epochId[poolId] = 1;
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(
        PoolId poolId,
        bytes16 shareClassId_,
        uint128 amount,
        address investor,
        address depositAssetId
    ) external auth {
        _ensureShareClassExists(poolId, shareClassId_);

        _updateDepositRequest(poolId, shareClassId_, int128(amount), investor, depositAssetId);
    }

    function cancelDepositRequest(PoolId poolId, bytes16 shareClassId_, address investor, address depositAssetId)
        external
        auth
        returns (uint128 cancelledAssetAmount)
    {
        _ensureShareClassExists(poolId, shareClassId_);

        cancelledAssetAmount = depositRequest[shareClassId_][depositAssetId][investor].pending;

        _updateDepositRequest(poolId, shareClassId_, -int128(cancelledAssetAmount), investor, depositAssetId);
    }

    /// @inheritdoc IShareClassManager
    function requestRedeem(
        PoolId poolId,
        bytes16 shareClassId_,
        uint128 amount,
        address investor,
        address payoutAssetId
    ) external auth {
        _ensureShareClassExists(poolId, shareClassId_);

        _updateRedeemRequest(poolId, shareClassId_, int128(amount), investor, payoutAssetId);
    }

    /// @inheritdoc IShareClassManager
    function cancelRedeemRequest(PoolId poolId, bytes16 shareClassId_, address investor, address payoutAssetId)
        external
        auth
        returns (uint128 cancelledAmount)
    {
        _ensureShareClassExists(poolId, shareClassId_);

        cancelledAmount = redeemRequest[shareClassId_][payoutAssetId][investor].pending;

        _updateRedeemRequest(poolId, shareClassId_, -int128(cancelledAmount), investor, payoutAssetId);
    }

    /// @inheritdoc IShareClassManager
    function approveDeposits(
        PoolId poolId,
        bytes16 shareClassId_,
        D18 approvalRatio,
        address paymentAssetId,
        IERC7726Ext valuation
    ) external auth returns (uint128 approvedPoolAmount, uint128 approvedAssetAmount) {
        _ensureShareClassExists(poolId, shareClassId_);
        require(approvalRatio.inner() <= 1e18, ISingleShareClass.MaxApprovalRatioExceeded());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(
            assetEpochState[shareClassId_][paymentAssetId].latestDepositApproval != approvalEpochId,
            ISingleShareClass.AlreadyApproved()
        );

        // Reduce pending
        approvedAssetAmount = approvalRatio.mulUint128(pendingDeposit[shareClassId_][paymentAssetId]);
        pendingDeposit[shareClassId_][paymentAssetId] -= approvedAssetAmount;
        uint128 pendingDepositPostUpdate = pendingDeposit[shareClassId_][paymentAssetId];

        // Increase approved
        address poolCurrency = poolRegistry.currency(poolId).addr();
        D18 paymentAssetPrice = valuation.getFactor(paymentAssetId, poolCurrency);
        approvedPoolAmount = paymentAssetPrice.mulUint128(approvedAssetAmount);

        // Update epoch data
        epoch[shareClassId_][approvalEpochId].approvedDepositAmount += approvedPoolAmount;

        EpochRatio storage epochRatio_ = epochRatio[shareClassId_][paymentAssetId][approvalEpochId];
        epochRatio_.approvedDepositAssetAmount = approvedAssetAmount;
        epochRatio_.approvedDepositPoolAmount = approvedPoolAmount;

        assetEpochState[shareClassId_][paymentAssetId].latestDepositApproval = approvalEpochId;

        emit IShareClassManager.ApprovedDeposits(
            poolId,
            shareClassId_,
            approvalEpochId,
            paymentAssetId,
            approvalRatio,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingDepositPostUpdate,
            paymentAssetPrice
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(
        PoolId poolId,
        bytes16 shareClassId_,
        D18 approvalRatio,
        address payoutAssetId,
        IERC7726Ext valuation
    ) external auth returns (uint128 approvedShareAmount, uint128 pendingShareAmount) {
        _ensureShareClassExists(poolId, shareClassId_);
        require(approvalRatio.inner() <= 1e18, ISingleShareClass.MaxApprovalRatioExceeded());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(
            assetEpochState[shareClassId_][payoutAssetId].latestRedeemApproval != approvalEpochId,
            ISingleShareClass.AlreadyApproved()
        );

        // Reduce pending
        approvedShareAmount = approvalRatio.mulUint128(pendingRedeem[shareClassId_][payoutAssetId]);
        pendingRedeem[shareClassId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount = pendingRedeem[shareClassId_][payoutAssetId];

        // Increase approved
        address poolCurrency = poolRegistry.currency(poolId).addr();
        D18 assetToPool = valuation.getFactor(payoutAssetId, poolCurrency);

        // Update epoch data
        epoch[shareClassId_][approvalEpochId].approvedShareAmount += approvedShareAmount;

        EpochRatio storage epochRatio_ = epochRatio[shareClassId_][payoutAssetId][approvalEpochId];
        epochRatio_.redeemRatio = approvalRatio;
        epochRatio_.redeemAssetToPoolQuote = assetToPool;

        assetEpochState[shareClassId_][payoutAssetId].latestRedeemApproval = approvalEpochId;

        emit IShareClassManager.ApprovedRedeems(
            poolId,
            shareClassId_,
            approvalEpochId,
            payoutAssetId,
            approvalRatio,
            approvedShareAmount,
            pendingShareAmount,
            assetToPool
        );
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, bytes16 shareClassId_, address depositAssetId, D18 navPerShare) external auth {
        AssetEpochState memory assetEpochState_ = assetEpochState[shareClassId_][depositAssetId];
        require(
            assetEpochState_.latestDepositApproval > assetEpochState_.latestIssuance,
            ISingleShareClass.ApprovalRequired()
        );

        issueSharesUntilEpoch(
            poolId, shareClassId_, depositAssetId, navPerShare, assetEpochState_.latestDepositApproval
        );
    }

    /// @inheritdoc ISingleShareClass
    function issueSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId_,
        address depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth {
        _ensureShareClassExists(poolId, shareClassId_);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        uint128 totalIssuance_ = totalIssuance[shareClassId_];

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = assetEpochState[shareClassId_][depositAssetId].latestIssuance + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            // Skip redeem epochs
            if (epochRatio[shareClassId_][depositAssetId][epochId_].approvedDepositAssetAmount == 0) {
                continue;
            }

            uint128 newShareAmount =
                navPerShare.reciprocalMulUint128(epoch[shareClassId_][epochId_].approvedDepositAmount);
            epochRatio[shareClassId_][depositAssetId][epochId_].depositShareToPoolQuote = navPerShare;
            totalIssuance_ += newShareAmount;
            uint128 nav = navPerShare.mulUint128(totalIssuance_);

            emit IShareClassManager.IssuedShares(poolId, shareClassId_, epochId_, navPerShare, nav, newShareAmount);
        }

        totalIssuance[shareClassId_] = totalIssuance_;
        assetEpochState[shareClassId_][depositAssetId].latestIssuance = endEpochId;
        _shareClassNavPerShare[shareClassId_] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, bytes16 shareClassId_, address payoutAssetId, D18 navPerShare)
        external
        auth
        returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount)
    {
        AssetEpochState memory assetEpochState_ = assetEpochState[shareClassId_][payoutAssetId];
        require(
            assetEpochState_.latestRedeemApproval > assetEpochState_.latestRevocation,
            ISingleShareClass.ApprovalRequired()
        );

        return revokeSharesUntilEpoch(
            poolId, shareClassId_, payoutAssetId, navPerShare, assetEpochState_.latestRedeemApproval
        );
    }

    /// @inheritdoc ISingleShareClass
    function revokeSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId_,
        address payoutAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount) {
        _ensureShareClassExists(poolId, shareClassId_);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        uint128 totalIssuance_ = totalIssuance[shareClassId_];

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = assetEpochState[shareClassId_][payoutAssetId].latestRevocation + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            EpochRatio storage epochRatio_ = epochRatio[shareClassId_][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochRatio_.redeemRatio.inner() == 0) {
                continue;
            }

            uint128 revokedShareAmount = epoch[shareClassId_][epochId_].approvedShareAmount;

            // payout = shares * navPerShare
            uint128 epochPoolAmount = navPerShare.mulUint128(revokedShareAmount);

            epochRatio_.redeemShareToPoolQuote = navPerShare;
            payoutPoolAmount += epochPoolAmount;
            payoutAssetAmount += epochRatio_.redeemAssetToPoolQuote.reciprocalMulUint128(epochPoolAmount);
            totalIssuance_ -= revokedShareAmount;
            uint128 nav = navPerShare.mulUint128(totalIssuance_);

            emit IShareClassManager.RevokedShares(poolId, shareClassId_, epochId_, navPerShare, nav, revokedShareAmount);
        }

        totalIssuance[shareClassId_] = totalIssuance_;
        assetEpochState[shareClassId_][payoutAssetId].latestRevocation = endEpochId;
        _shareClassNavPerShare[shareClassId_] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, bytes16 shareClassId_, address investor, address depositAssetId)
        external
        returns (uint128 payoutShareAmount, uint128 paymentAssetAmount)
    {
        return claimDepositUntilEpoch(
            poolId,
            shareClassId_,
            investor,
            depositAssetId,
            assetEpochState[shareClassId_][depositAssetId].latestIssuance
        );
    }

    /// @inheritdoc ISingleShareClass
    function claimDepositUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId_,
        address investor,
        address depositAssetId,
        uint32 endEpochId
    ) public returns (uint128 payoutShareAmount, uint128 paymentAssetAmount) {
        _ensureShareClassExists(poolId, shareClassId_);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        UserOrder storage userOrder = depositRequest[shareClassId_][depositAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochRatio memory epochRatio_ = epochRatio[shareClassId_][depositAssetId][epochId_];

            // Skip redeem epochs
            if (epochRatio_.approvedDepositAssetAmount == 0) {
                continue;
            }

            D18 userRatio = d18(userOrder.pending, pendingDeposit[shareClassId_][depositAssetId]);
            uint128 approvedAssetAmount = userRatio.mulUint128(epochRatio_.approvedDepositAssetAmount);

            // #shares = poolAmount / shareToPool
            uint128 investorShareAmount = epochRatio_.depositShareToPoolQuote.reciprocalMulUint128(
                userRatio.mulUint128(epochRatio_.approvedDepositPoolAmount)
            );

            userOrder.pending -= approvedAssetAmount;
            payoutShareAmount += investorShareAmount;
            paymentAssetAmount += approvedAssetAmount;

            emit IShareClassManager.ClaimedDeposit(
                poolId,
                shareClassId_,
                epochId_,
                investor,
                depositAssetId,
                approvedAssetAmount,
                userOrder.pending,
                investorShareAmount
            );
        }

        userOrder.lastUpdate = endEpochId + 1;
    }

    /// @inheritdoc IShareClassManager
    function claimRedeem(PoolId poolId, bytes16 shareClassId_, address investor, address payoutAssetId)
        external
        returns (uint128 payoutAssetAmount, uint128 paymentShareAmount)
    {
        return claimRedeemUntilEpoch(
            poolId,
            shareClassId_,
            investor,
            payoutAssetId,
            assetEpochState[shareClassId_][payoutAssetId].latestRevocation
        );
    }

    /// @inheritdoc ISingleShareClass
    function claimRedeemUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId_,
        address investor,
        address payoutAssetId,
        uint32 endEpochId
    ) public returns (uint128 payoutAssetAmount, uint128 paymentShareAmount) {
        _ensureShareClassExists(poolId, shareClassId_);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        UserOrder storage userOrder = redeemRequest[shareClassId_][payoutAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochRatio memory epochRatio_ = epochRatio[shareClassId_][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochRatio_.redeemRatio.inner() == 0) {
                continue;
            }

            uint128 approvedShareAmount = epochRatio_.redeemRatio.mulUint128(userOrder.pending);

            // assetAmount = poolAmount * poolToAsset = poolAmount / assetToPool = (#shares * shareToPool) / assetToPool
            uint128 approvedAssetAmount = epochRatio_.redeemAssetToPoolQuote.reciprocalMulUint128(
                epochRatio_.redeemShareToPoolQuote.mulUint128(approvedShareAmount)
            );

            paymentShareAmount += approvedShareAmount;
            payoutAssetAmount += approvedAssetAmount;

            userOrder.pending -= approvedShareAmount;

            emit IShareClassManager.ClaimedRedeem(
                poolId,
                shareClassId_,
                epochId_,
                investor,
                payoutAssetId,
                approvedShareAmount,
                userOrder.pending,
                approvedAssetAmount
            );
        }

        userOrder.lastUpdate = endEpochId + 1;
    }

    /// @inheritdoc IShareClassManager
    function updateShareClassNav(PoolId poolId, bytes16 shareClassId_) external view auth returns (D18, uint128) {
        _ensureShareClassExists(poolId, shareClassId_);
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function update(PoolId, bytes calldata) external pure {
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function shareClassNavPerShare(PoolId poolId, bytes16 shareClassId_)
        external
        view
        returns (D18 navPerShare, uint128 issuance)
    {
        _ensureShareClassExists(poolId, shareClassId_);

        return (_shareClassNavPerShare[shareClassId_], totalIssuance[shareClassId_]);
    }

    /// @notice Updates the amount of a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId_ Identifier of the share class
    /// @param amount Asset token amount which is updated
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function _updateDepositRequest(
        PoolId poolId,
        bytes16 shareClassId_,
        int128 amount,
        address investor,
        address depositAssetId
    ) private {
        UserOrder storage userOrder = depositRequest[shareClassId_][depositAssetId][investor];

        // Block updates until pending amount does not impact claimable amount, i.e. last update happened after latest
        // approval
        uint32 latestApproval = assetEpochState[shareClassId_][depositAssetId].latestDepositApproval;
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            IShareClassManager.ClaimDepositRequired()
        );

        userOrder.lastUpdate = epochId[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint128(amount) : userOrder.pending - uint128(-amount);

        pendingDeposit[shareClassId_][depositAssetId] = amount >= 0
            ? pendingDeposit[shareClassId_][depositAssetId] + uint128(amount)
            : pendingDeposit[shareClassId_][depositAssetId] - uint128(-amount);

        emit IShareClassManager.UpdatedDepositRequest(
            poolId,
            shareClassId_,
            epochId[poolId],
            investor,
            depositAssetId,
            userOrder.pending,
            pendingDeposit[shareClassId_][depositAssetId]
        );
    }

    /// @notice Updates the amount of a request to redeem (exchange) share class tokens for an asset.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId_ Identifier of the share class
    /// @param amount Share class token amount which is updated
    /// @param investor Address of the entity which is depositing
    /// @param payoutAssetId Identifier of the asset which the investor wants to offramp to
    function _updateRedeemRequest(
        PoolId poolId,
        bytes16 shareClassId_,
        int128 amount,
        address investor,
        address payoutAssetId
    ) private {
        UserOrder storage userOrder = redeemRequest[shareClassId_][payoutAssetId][investor];

        // Block updates until pending amount does not impact claimable amount
        uint32 latestApproval = assetEpochState[shareClassId_][payoutAssetId].latestRedeemApproval;
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            IShareClassManager.ClaimRedeemRequired()
        );

        userOrder.lastUpdate = epochId[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint128(amount) : userOrder.pending - uint128(-amount);

        pendingRedeem[shareClassId_][payoutAssetId] = amount >= 0
            ? pendingRedeem[shareClassId_][payoutAssetId] + uint128(amount)
            : pendingRedeem[shareClassId_][payoutAssetId] - uint128(-amount);

        emit IShareClassManager.UpdatedRedeemRequest(
            poolId,
            shareClassId_,
            epochId[poolId],
            investor,
            payoutAssetId,
            userOrder.pending,
            pendingRedeem[shareClassId_][payoutAssetId]
        );
    }

    /// @notice Advances the current epoch of the given pool if it has not been incremented within the multicall. If the
    /// epoch has already been incremented, we don't bump it again to allow deposit and redeem approvals to point to the
    /// same epoch id. Emits NewEpoch event if the epoch is advanced.
    ///
    /// @param poolId Identifier of the pool for which we want to advance an epoch.
    /// @return epochIdCurrentBlock Identifier of the current epoch. E.g., if the epoch advanced from i to i+1, i is
    /// returned.
    function _advanceEpoch(PoolId poolId) private returns (uint32 epochIdCurrentBlock) {
        uint32 epochId_ = epochId[poolId];

        // Epoch doesn't necessarily advance, e.g. in case of multiple approvals inside the same multiCall
        if (_epochIncrement == 0) {
            _epochIncrement = 1;
            uint32 newEpochId = epochId_ + 1;
            epochId[poolId] = newEpochId;

            emit IShareClassManager.NewEpoch(poolId, newEpochId);

            return epochId_;
        } else {
            return uint32(uint128(epochId_ - 1).max(1));
        }
    }

    /// @notice Ensures the given share class id is linked to the given pool id. If not, reverts.
    ///
    /// @param poolId Identifier of the pool.
    /// @param shareClassId_ Identifier of the share class to be checked.
    function _ensureShareClassExists(PoolId poolId, bytes16 shareClassId_) private view {
        require(shareClassId[poolId] == shareClassId_, IShareClassManager.ShareClassNotFound());
    }
}

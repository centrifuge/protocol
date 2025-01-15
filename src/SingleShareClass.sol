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

import {console} from "forge-std/console.sol";

struct Epoch {
    /// @dev Amount of approved deposits (in pool denomination)
    uint256 approvedDeposits;
    /// @dev Amount of approved shares (in share denomination)
    uint256 approvedShares;
}

struct EpochRatio {
    /// @dev Percentage of approved deposits
    D18 depositRatio;
    /// @dev Percentage of approved redemptions
    D18 redeemRatio;
    /// @dev Price of one pool per asset token set during redeem approval
    D18 depositAssetToPoolQuote;
    /// @dev Price of one pool per asset token set during redeem approval
    D18 redeemAssetToPoolQuote;
    /// @dev Price of one pool per share class token set during deposit flow
    D18 depositShareToPoolQuote;
    /// @dev Price of one pool per share class token set during redeem flow
    D18 redeemShareToPoolQuote;
}

struct UserOrder {
    /// @dev Pending amount in deposit asset denomination
    uint256 pending;
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
    using MathLib for uint256;

    /// Storage
    // TODO: Reorder for optimal storage layout
    // uint32 private transient _epochIncrement;
    uint32 private /*transient*/ _epochIncrement;
    IPoolRegistry public poolRegistry;
    uint32 public shareClassIdCounter;
    mapping(PoolId poolId => bytes16) public shareClassIds;
    // User storage
    mapping(bytes16 scId => mapping(address paymentAssetId => mapping(address investor => UserOrder pending))) public
        depositRequest;
    mapping(bytes16 scId => mapping(address payoutAssetId => mapping(address investor => UserOrder pending))) public
        redeemRequest;
    // Share class storage
    mapping(bytes16 scId => mapping(address paymentAssetId => uint256 pending)) public pendingDeposit;
    mapping(bytes16 scId => mapping(address payoutAssetId => uint256 pending)) public pendingRedeem;
    mapping(bytes16 scId => D18 navPerShare) private _shareClassNavPerShare;
    mapping(bytes16 scId => uint256) public totalIssuance;
    // Share class + epoch storage
    mapping(PoolId poolId => uint32 epochId_) public epochId;
    mapping(bytes16 scId => mapping(uint32 epochId_ => Epoch epoch)) public epoch;
    mapping(bytes16 scId => mapping(address assetId => AssetEpochState)) public assetEpochState;
    mapping(bytes16 scId => mapping(address assetId => mapping(uint32 epochId_ => EpochRatio epoch))) public epochRatio;

    constructor(address poolRegistry_, address deployer) Auth(deployer) {
        poolRegistry = IPoolRegistry(poolRegistry_);
    }

    function file(bytes32 what, address data) external auth {
        require(what == "poolRegistry", ISingleShareClass.UnrecognizedFileParam());
        poolRegistry = IPoolRegistry(data);
        emit ISingleShareClass.File(what, data);
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId poolId, bytes calldata /* data */ ) external auth returns (bytes16 shareClassId) {
        require(shareClassIds[poolId] == bytes16(0), IShareClassManager.MaxShareClassNumberExceeded(1));

        shareClassId = bytes16(keccak256(abi.encode(poolId, shareClassIdCounter++)));

        shareClassIds[poolId] = shareClassId;
        epochId[poolId] = 1;
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(
        PoolId poolId,
        bytes16 shareClassId,
        uint256 amount,
        address investor,
        address depositAssetId
    ) external auth {
        _ensureShareClassExists(poolId, shareClassId);

        _updateDepositRequest(poolId, shareClassId, int256(amount), investor, depositAssetId);
    }

    function cancelDepositRequest(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        auth
    {
        _ensureShareClassExists(poolId, shareClassId);

        _updateDepositRequest(
            poolId,
            shareClassId,
            -int256(depositRequest[shareClassId][depositAssetId][investor].pending),
            investor,
            depositAssetId
        );
    }

    /// @inheritdoc IShareClassManager
    function requestRedeem(PoolId poolId, bytes16 shareClassId, uint256 amount, address investor, address payoutAssetId)
        external
        auth
    {
        _ensureShareClassExists(poolId, shareClassId);

        _updateRedeemRequest(poolId, shareClassId, int256(amount), investor, payoutAssetId);
    }

    /// @inheritdoc IShareClassManager
    function cancelRedeemRequest(PoolId poolId, bytes16 shareClassId, address investor, address payoutAssetId)
        external
        auth
    {
        _ensureShareClassExists(poolId, shareClassId);

        _updateRedeemRequest(
            poolId,
            shareClassId,
            -int256(redeemRequest[shareClassId][payoutAssetId][investor].pending),
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
        _ensureShareClassExists(poolId, shareClassId);
        require(approvalRatio.inner() <= 1e18, ISingleShareClass.MaxApprovalRatioExceeded());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(
            assetEpochState[shareClassId][paymentAssetId].latestDepositApproval != approvalEpochId,
            ISingleShareClass.AlreadyApproved()
        );

        // Reduce pending
        approvedAssetAmount = approvalRatio.mulUint256(pendingDeposit[shareClassId][paymentAssetId]);
        pendingDeposit[shareClassId][paymentAssetId] -= approvedAssetAmount;
        uint256 pendingDepositPostUpdate = pendingDeposit[shareClassId][paymentAssetId];

        // Increase approved
        address poolCurrency = address(poolRegistry.currency(poolId));
        D18 paymentAssetPrice = valuation.getFactor(paymentAssetId, poolCurrency);
        approvedPoolAmount = paymentAssetPrice.mulUint256(approvedAssetAmount);

        // Update epoch data
        epoch[shareClassId][approvalEpochId].approvedDeposits += approvedPoolAmount;

        EpochRatio storage epochRatio_ = epochRatio[shareClassId][paymentAssetId][approvalEpochId];
        epochRatio_.depositRatio = approvalRatio;
        epochRatio_.depositAssetToPoolQuote = paymentAssetPrice;

        assetEpochState[shareClassId][paymentAssetId].latestDepositApproval = approvalEpochId;

        emit IShareClassManager.ApprovedDeposits(
            poolId,
            shareClassId,
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
        bytes16 shareClassId,
        D18 approvalRatio,
        address payoutAssetId,
        IERC7726Ext valuation
    ) external auth returns (uint256 approvedShares, uint256 pendingShares) {
        _ensureShareClassExists(poolId, shareClassId);
        require(approvalRatio.inner() <= 1e18, ISingleShareClass.MaxApprovalRatioExceeded());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(
            assetEpochState[shareClassId][payoutAssetId].latestRedeemApproval != approvalEpochId,
            ISingleShareClass.AlreadyApproved()
        );

        // Reduce pending
        approvedShares = approvalRatio.mulUint256(pendingRedeem[shareClassId][payoutAssetId]);
        pendingRedeem[shareClassId][payoutAssetId] -= approvedShares;
        pendingShares = pendingRedeem[shareClassId][payoutAssetId];

        // Increase approved
        address poolCurrency = address(poolRegistry.currency(poolId));
        D18 assetToPool = valuation.getFactor(payoutAssetId, poolCurrency);

        // Update epoch data
        epoch[shareClassId][approvalEpochId].approvedShares += approvedShares;

        EpochRatio storage epochRatio_ = epochRatio[shareClassId][payoutAssetId][approvalEpochId];
        epochRatio_.redeemRatio = approvalRatio;
        console.log("Setting %d epoch redeemAssetToPoolQuote to", approvalEpochId, assetToPool.inner());
        epochRatio_.redeemAssetToPoolQuote = assetToPool;

        assetEpochState[shareClassId][payoutAssetId].latestRedeemApproval = approvalEpochId;

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
        AssetEpochState memory assetEpochState_ = assetEpochState[shareClassId][depositAssetId];
        require(
            assetEpochState_.latestDepositApproval > assetEpochState_.latestIssuance,
            ISingleShareClass.ApprovalRequired()
        );

        issueSharesUntilEpoch(poolId, shareClassId, depositAssetId, navPerShare, assetEpochState_.latestDepositApproval);
    }

    /// @inheritdoc ISingleShareClass
    function issueSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth {
        _ensureShareClassExists(poolId, shareClassId);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        uint256 totalIssuance_ = totalIssuance[shareClassId];

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = assetEpochState[shareClassId][depositAssetId].latestIssuance + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            // Skip redeem epochs
            if (epochRatio[shareClassId][depositAssetId][epochId_].depositRatio.inner() == 0) {
                continue;
            }

            uint256 newShares = navPerShare.reciprocalMulUint256(epoch[shareClassId][epochId_].approvedDeposits);
            epochRatio[shareClassId][depositAssetId][epochId_].depositShareToPoolQuote = navPerShare;
            totalIssuance_ += newShares;
            uint256 nav = navPerShare.mulUint256(totalIssuance_);

            emit IShareClassManager.IssuedShares(poolId, shareClassId, epochId_, navPerShare, nav, newShares);
        }

        totalIssuance[shareClassId] = totalIssuance_;
        assetEpochState[shareClassId][depositAssetId].latestIssuance = endEpochId;
        _shareClassNavPerShare[shareClassId] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(PoolId poolId, bytes16 shareClassId, address payoutAssetId, D18 navPerShare)
        external
        auth
        returns (uint256 payoutAssetAmount, uint256 payoutPoolAmount)
    {
        AssetEpochState memory assetEpochState_ = assetEpochState[shareClassId][payoutAssetId];
        require(
            assetEpochState_.latestRedeemApproval > assetEpochState_.latestRevocation,
            ISingleShareClass.ApprovalRequired()
        );

        return revokeSharesUntilEpoch(
            poolId, shareClassId, payoutAssetId, navPerShare, assetEpochState_.latestRedeemApproval
        );
    }

    /// @inheritdoc ISingleShareClass
    function revokeSharesUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address payoutAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth returns (uint256 payoutAssetAmount, uint256 payoutPoolAmount) {
        _ensureShareClassExists(poolId, shareClassId);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        uint256 totalIssuance_ = totalIssuance[shareClassId];

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = assetEpochState[shareClassId][payoutAssetId].latestRevocation + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            EpochRatio storage epochRatio_ = epochRatio[shareClassId][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochRatio_.redeemRatio.inner() == 0) {
                continue;
            }

            uint256 revokedShares = epoch[shareClassId][epochId_].approvedShares;

            // payout = shares * navPerShare
            uint256 epochPoolAmount = navPerShare.mulUint256(revokedShares);

            epochRatio_.redeemShareToPoolQuote = navPerShare;
            payoutPoolAmount += epochPoolAmount;
            payoutAssetAmount += epochRatio_.redeemAssetToPoolQuote.reciprocalMulUint256(epochPoolAmount);
            totalIssuance_ -= revokedShares;
            uint256 nav = navPerShare.mulUint256(totalIssuance_);

            emit IShareClassManager.RevokedShares(poolId, shareClassId, epochId_, navPerShare, nav, revokedShares);
        }

        totalIssuance[shareClassId] = totalIssuance_;
        assetEpochState[shareClassId][payoutAssetId].latestRevocation = endEpochId;
        _shareClassNavPerShare[shareClassId] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, bytes16 shareClassId, address investor, address depositAssetId)
        external
        returns (uint256 payoutShareAmount, uint256 paymentAssetAmount)
    {
        return claimDepositUntilEpoch(
            poolId, shareClassId, investor, depositAssetId, assetEpochState[shareClassId][depositAssetId].latestIssuance
        );
    }

    /// @inheritdoc ISingleShareClass
    function claimDepositUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address depositAssetId,
        uint32 endEpochId
    ) public returns (uint256 payoutShares, uint256 paymentAssetAmount) {
        _ensureShareClassExists(poolId, shareClassId);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        UserOrder storage userOrder = depositRequest[shareClassId][depositAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochRatio memory epochRatio_ = epochRatio[shareClassId][depositAssetId][epochId_];

            // Skip redeem epochs
            if (epochRatio_.depositRatio.inner() == 0) {
                continue;
            }

            uint256 approvedAssetAmount = epochRatio_.depositRatio.mulUint256(userOrder.pending);

            // #shares = poolAmount * poolToShares * poolAmount = (assetToPool * assetAmount) / shareToPool
            uint256 investorShares = epochRatio_.depositShareToPoolQuote.reciprocalMulUint256(
                epochRatio_.depositAssetToPoolQuote.mulUint256(approvedAssetAmount)
            );

            userOrder.pending -= approvedAssetAmount;
            payoutShares += investorShares;
            paymentAssetAmount += approvedAssetAmount;

            emit IShareClassManager.ClaimedDeposit(
                poolId,
                shareClassId,
                epochId_,
                investor,
                depositAssetId,
                approvedAssetAmount,
                userOrder.pending,
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
            poolId, shareClassId, investor, payoutAssetId, assetEpochState[shareClassId][payoutAssetId].latestRevocation
        );
    }

    /// @inheritdoc ISingleShareClass
    function claimRedeemUntilEpoch(
        PoolId poolId,
        bytes16 shareClassId,
        address investor,
        address payoutAssetId,
        uint32 endEpochId
    ) public returns (uint256 payoutAssetAmount, uint256 paymentShares) {
        _ensureShareClassExists(poolId, shareClassId);
        require(endEpochId < epochId[poolId], IShareClassManager.EpochNotFound());

        UserOrder storage userOrder = redeemRequest[shareClassId][payoutAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochRatio memory epochRatio_ = epochRatio[shareClassId][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochRatio_.redeemRatio.inner() == 0) {
                continue;
            }

            uint256 approvedShares = epochRatio_.redeemRatio.mulUint256(userOrder.pending);

            // assetAmount = poolAmount * poolToAsset = poolAmount / assetToPool = (#shares * shareToPool) / assetToPool
            uint256 approvedAssetAmount = epochRatio_.redeemAssetToPoolQuote.reciprocalMulUint256(
                epochRatio_.redeemShareToPoolQuote.mulUint256(approvedShares)
            );

            paymentShares += approvedShares;
            payoutAssetAmount += approvedAssetAmount;

            userOrder.pending -= approvedShares;

            emit IShareClassManager.ClaimedRedeem(
                poolId,
                shareClassId,
                epochId_,
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
    function updateShareClassNav(PoolId poolId, bytes16 shareClassId) external view auth returns (D18, uint256) {
        _ensureShareClassExists(poolId, shareClassId);

        // TODO(@mustermeiszer): Needed for single share class?
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function update(PoolId, bytes calldata) external pure {
        // TODO(@mustermeiszer): Needed for single share class?
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function shareClassNavPerShare(PoolId poolId, bytes16 shareClassId)
        external
        view
        returns (D18 navPerShare, uint256 issuance)
    {
        _ensureShareClassExists(poolId, shareClassId);

        return (_shareClassNavPerShare[shareClassId], totalIssuance[shareClassId]);
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
        UserOrder storage userOrder = depositRequest[shareClassId][depositAssetId][investor];

        // Block updates until pending amount does not impact claimable amount, i.e. last update happened after latest
        // approval
        uint32 latestApproval = assetEpochState[shareClassId][depositAssetId].latestDepositApproval;
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            IShareClassManager.ClaimDepositRequired()
        );

        userOrder.lastUpdate = epochId[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint256(amount) : userOrder.pending - uint256(-amount);

        pendingDeposit[shareClassId][depositAssetId] = amount >= 0
            ? pendingDeposit[shareClassId][depositAssetId] + uint256(amount)
            : pendingDeposit[shareClassId][depositAssetId] - uint256(-amount);

        emit IShareClassManager.UpdatedDepositRequest(
            poolId,
            shareClassId,
            epochId[poolId],
            investor,
            depositAssetId,
            userOrder.pending,
            pendingDeposit[shareClassId][depositAssetId]
        );
    }

    /// @notice Updates the amount of a request to redeem (exchange) share class tokens for an asset.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId Identifier of the share class
    /// @param amount Share class token amount which is updated
    /// @param investor Address of the entity which is depositing
    /// @param payoutAssetId Identifier of the asset which the investor wants to offramp to
    function _updateRedeemRequest(
        PoolId poolId,
        bytes16 shareClassId,
        int256 amount,
        address investor,
        address payoutAssetId
    ) private {
        UserOrder storage userOrder = redeemRequest[shareClassId][payoutAssetId][investor];

        // Block updates until pending amount does not impact claimable amount
        uint32 latestApproval = assetEpochState[shareClassId][payoutAssetId].latestRedeemApproval;
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            IShareClassManager.ClaimRedeemRequired()
        );

        userOrder.lastUpdate = epochId[poolId];
        userOrder.pending = amount >= 0 ? userOrder.pending + uint256(amount) : userOrder.pending - uint256(-amount);

        pendingRedeem[shareClassId][payoutAssetId] = amount >= 0
            ? pendingRedeem[shareClassId][payoutAssetId] + uint256(amount)
            : pendingRedeem[shareClassId][payoutAssetId] - uint256(-amount);

        emit IShareClassManager.UpdatedRedeemRequest(
            poolId,
            shareClassId,
            epochId[poolId],
            investor,
            payoutAssetId,
            userOrder.pending,
            pendingRedeem[shareClassId][payoutAssetId]
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
            return uint32(uint256(epochId_ - 1).max(1));
        }
    }

    /// @notice Ensures the given share class id is linked to the given pool id. If not, reverts.
    ///
    /// @param poolId Identifier of the pool.
    /// @param shareClassId Identifier of the share class to be checked.
    function _ensureShareClassExists(PoolId poolId, bytes16 shareClassId) private view {
        require(shareClassIds[poolId] == shareClassId, IShareClassManager.ShareClassNotFound());
    }
}

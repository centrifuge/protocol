// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {ISingleShareClass} from "src/pools/interfaces/ISingleShareClass.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";

struct EpochAmounts {
    /// @dev Percentage of approved deposits
    D18 depositApprovalRate;
    /// @dev Percentage of approved redemptions
    D18 redeemApprovalRate;
    /// @dev Total approved asset amount of deposit asset
    uint128 depositAssetAmount;
    /// @dev Total approved pool amount of deposit asset
    uint128 depositPoolAmount;
    /// @dev Total number of share class tokens issued
    uint128 depositSharesIssued;
    /// @dev Total asset amount of revoked share class tokens
    uint128 redeemAssetAmount;
    /// @dev Total approved amount of redeemed share class tokens
    uint128 redeemSharesRevoked;
}

struct UserOrder {
    /// @dev Pending amount in deposit asset denomination
    uint128 pending;
    /// @dev Index of epoch in which last order was made
    uint32 lastUpdate;
}

struct EpochPointers {
    /// @dev The last epoch in which a deposit approval was made
    uint32 latestDepositApproval;
    /// @dev The last epoch in which a redeem approval was made
    uint32 latestRedeemApproval;
    /// @dev The last epoch in which shares were issued
    uint32 latestIssuance;
    /// @dev The last epoch in which a shares were revoked
    uint32 latestRevocation;
}

struct ShareClassMetadata {
    string name;
    string symbol;
    bytes32 salt;
}

/// Utility method to determine the ShareClassId for a PoolId
function previewShareClassId(PoolId poolId) pure returns (ShareClassId) {
    return ShareClassId.wrap(bytes16(uint128(PoolId.unwrap(poolId))));
}

contract SingleShareClass is Auth, ISingleShareClass {
    using MathLib for D18;
    using MathLib for uint128;
    using MathLib for uint256;
    using CastLib for bytes;
    using CastLib for bytes32;
    using BytesLib for bytes;

    uint32 constant META_NAME_LENGTH = 128;
    uint32 constant META_SYMBOL_LENGTH = 32;

    /// Storage
    uint32 internal transient _epochIncrement;
    IPoolRegistry public poolRegistry;
    mapping(bytes32 salt => bool) public salts;
    mapping(PoolId poolId => uint32 epochId_) public epochId;
    mapping(PoolId poolId => ShareClassId) public shareClassId;
    mapping(ShareClassId scId => uint128) public totalIssuance;
    mapping(ShareClassId scId => ShareClassMetadata) public metadata;
    mapping(ShareClassId scId => D18 navPerShare) private _shareClassNavPerShare;
    mapping(ShareClassId scId => mapping(AssetId assetId => EpochPointers)) public epochPointers;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => uint128 pending)) public pendingRedeem;
    mapping(ShareClassId scId => mapping(AssetId paymentAssetId => uint128 pending)) public pendingDeposit;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(uint32 epochId_ => EpochAmounts epoch))) public
        epochAmounts;
    mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
        public redeemRequest;
    mapping(ShareClassId scId => mapping(AssetId paymentAssetId => mapping(bytes32 investor => UserOrder pending)))
        public depositRequest;

    constructor(IPoolRegistry poolRegistry_, address deployer) Auth(deployer) {
        poolRegistry = poolRegistry_;
    }

    function file(bytes32 what, address data) external auth {
        require(what == "poolRegistry", UnrecognizedFileParam());
        poolRegistry = IPoolRegistry(data);
        emit File(what, data);
    }

    /// @inheritdoc IShareClassManager
    function addShareClass(PoolId poolId, string calldata name, string calldata symbol, bytes32 salt, bytes calldata) external auth returns (ShareClassId shareClassId_) {
        require(shareClassId[poolId].isNull(), MaxShareClassNumberExceeded(1));

        shareClassId_ = previewShareClassId(poolId);

        shareClassId[poolId] = shareClassId_;
        epochId[poolId] = 1;

        _updateMetadata(shareClassId_, name, symbol, salt);

        emit AddedShareClass(poolId, shareClassId_, name, symbol, salt);
    }

    /// @inheritdoc IShareClassManager
    function requestDeposit(
        PoolId poolId,
        ShareClassId shareClassId_,
        uint128 amount,
        bytes32 investor,
        AssetId depositAssetId
    ) external auth {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());

        // NOTE: CV ensures amount > 0
        _updateDepositRequest(poolId, shareClassId_, amount, true, investor, depositAssetId);
    }

    function cancelDepositRequest(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId)
        external
        auth
        returns (uint128 cancelledAssetAmount)
    {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());

        cancelledAssetAmount = depositRequest[shareClassId_][depositAssetId][investor].pending;

        _updateDepositRequest(poolId, shareClassId_, cancelledAssetAmount, false, investor, depositAssetId);
    }

    /// @inheritdoc IShareClassManager
    function requestRedeem(
        PoolId poolId,
        ShareClassId shareClassId_,
        uint128 amount,
        bytes32 investor,
        AssetId payoutAssetId
    ) external auth {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());

        // NOTE: CV ensures amount > 0
        _updateRedeemRequest(poolId, shareClassId_, amount, true, investor, payoutAssetId);
    }

    /// @inheritdoc IShareClassManager
    function cancelRedeemRequest(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId)
        external
        auth
        returns (uint128 cancelledShareAmount)
    {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());

        cancelledShareAmount = redeemRequest[shareClassId_][payoutAssetId][investor].pending;

        _updateRedeemRequest(poolId, shareClassId_, cancelledShareAmount, false, investor, payoutAssetId);
    }

    /// @inheritdoc IShareClassManager
    function approveDeposits(
        PoolId poolId,
        ShareClassId shareClassId_,
        D18 approvalRatio,
        AssetId paymentAssetId,
        IERC7726 valuation
    ) external auth returns (uint128 approvedAssetAmount, uint128 approvedPoolAmount) {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        require(approvalRatio.inner() > 0 && approvalRatio.inner() <= 1e18, ApprovalRatioOutOfBounds());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(
            epochPointers[shareClassId_][paymentAssetId].latestDepositApproval != approvalEpochId, AlreadyApproved()
        );

        // Reduce pending
        approvedAssetAmount = approvalRatio.mulUint128(pendingDeposit[shareClassId_][paymentAssetId]);
        pendingDeposit[shareClassId_][paymentAssetId] -= approvedAssetAmount;
        uint128 pendingDepositPostUpdate = pendingDeposit[shareClassId_][paymentAssetId];

        // Increase approved
        address poolCurrency = poolRegistry.currency(poolId).addr();
        approvedPoolAmount =
            (IERC7726(valuation).getQuote(approvedAssetAmount, paymentAssetId.addr(), poolCurrency)).toUint128();

        // Update epoch data
        EpochAmounts storage epochAmounts_ = epochAmounts[shareClassId_][paymentAssetId][approvalEpochId];
        epochAmounts_.depositApprovalRate = approvalRatio;
        epochAmounts_.depositAssetAmount = approvedAssetAmount;
        epochAmounts_.depositPoolAmount = approvedPoolAmount;
        epochPointers[shareClassId_][paymentAssetId].latestDepositApproval = approvalEpochId;

        emit ApprovedDeposits(
            poolId,
            shareClassId_,
            approvalEpochId,
            paymentAssetId,
            approvalRatio,
            approvedPoolAmount,
            approvedAssetAmount,
            pendingDepositPostUpdate
        );
    }

    /// @inheritdoc IShareClassManager
    function approveRedeems(PoolId poolId, ShareClassId shareClassId_, D18 approvalRatio, AssetId payoutAssetId)
        external
        auth
        returns (uint128 approvedShareAmount, uint128 pendingShareAmount)
    {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        require(approvalRatio.inner() > 0 && approvalRatio.inner() <= 1e18, ApprovalRatioOutOfBounds());

        // Advance epochId if it has not been advanced within this transaction (e.g. in case of multiCall context)
        uint32 approvalEpochId = _advanceEpoch(poolId);

        // Block approvals for the same asset in the same epoch
        require(epochPointers[shareClassId_][payoutAssetId].latestRedeemApproval != approvalEpochId, AlreadyApproved());

        // Reduce pending
        approvedShareAmount = approvalRatio.mulUint128(pendingRedeem[shareClassId_][payoutAssetId]);
        pendingRedeem[shareClassId_][payoutAssetId] -= approvedShareAmount;
        pendingShareAmount = pendingRedeem[shareClassId_][payoutAssetId];

        // Update epoch data
        EpochAmounts storage epochAmounts_ = epochAmounts[shareClassId_][payoutAssetId][approvalEpochId];
        epochAmounts_.redeemApprovalRate = approvalRatio;
        epochAmounts_.redeemSharesRevoked = approvedShareAmount;

        epochPointers[shareClassId_][payoutAssetId].latestRedeemApproval = approvalEpochId;

        emit ApprovedRedeems(
            poolId,
            shareClassId_,
            approvalEpochId,
            payoutAssetId,
            approvalRatio,
            approvedShareAmount,
            pendingShareAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function issueShares(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, D18 navPerShare)
        external
        auth
    {
        EpochPointers storage epochPointers_ = epochPointers[shareClassId_][depositAssetId];
        require(epochPointers_.latestDepositApproval > epochPointers_.latestIssuance, ApprovalRequired());

        issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, navPerShare, epochPointers_.latestDepositApproval);
    }

    /// @inheritdoc ISingleShareClass
    function issueSharesUntilEpoch(
        PoolId poolId,
        ShareClassId shareClassId_,
        AssetId depositAssetId,
        D18 navPerShare,
        uint32 endEpochId
    ) public auth {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        uint128 totalIssuance_ = totalIssuance[shareClassId_];

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = epochPointers[shareClassId_][depositAssetId].latestIssuance + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            // Skip redeem epochs
            if (epochAmounts[shareClassId_][depositAssetId][epochId_].depositApprovalRate.inner() == 0) {
                continue;
            }

            uint128 newShareAmount = navPerShare.reciprocalMulUint128(
                epochAmounts[shareClassId_][depositAssetId][epochId_].depositPoolAmount
            );
            epochAmounts[shareClassId_][depositAssetId][epochId_].depositSharesIssued = newShareAmount;
            totalIssuance_ += newShareAmount;
            uint128 nav = navPerShare.mulUint128(totalIssuance_);

            emit IssuedShares(poolId, shareClassId_, epochId_, navPerShare, nav, newShareAmount);
        }

        totalIssuance[shareClassId_] = totalIssuance_;
        epochPointers[shareClassId_][depositAssetId].latestIssuance = endEpochId;
        _shareClassNavPerShare[shareClassId_] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function revokeShares(
        PoolId poolId,
        ShareClassId shareClassId_,
        AssetId payoutAssetId,
        D18 navPerShare,
        IERC7726 valuation
    ) external auth returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount) {
        EpochPointers storage epochPointers_ = epochPointers[shareClassId_][payoutAssetId];
        require(epochPointers_.latestRedeemApproval > epochPointers_.latestRevocation, ApprovalRequired());

        return revokeSharesUntilEpoch(
            poolId, shareClassId_, payoutAssetId, navPerShare, valuation, epochPointers_.latestRedeemApproval
        );
    }

    /// @inheritdoc ISingleShareClass
    function revokeSharesUntilEpoch(
        PoolId poolId,
        ShareClassId shareClassId_,
        AssetId payoutAssetId,
        D18 navPerShare,
        IERC7726 valuation,
        uint32 endEpochId
    ) public auth returns (uint128 payoutAssetAmount, uint128 payoutPoolAmount) {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        uint128 totalIssuance_ = totalIssuance[shareClassId_];
        address poolCurrency = poolRegistry.currency(poolId).addr();

        // First issuance starts at epoch 0, subsequent ones at latest pointer plus one
        uint32 startEpochId = epochPointers[shareClassId_][payoutAssetId].latestRevocation + 1;

        for (uint32 epochId_ = startEpochId; epochId_ <= endEpochId; epochId_++) {
            EpochAmounts storage epochAmounts_ = epochAmounts[shareClassId_][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochAmounts_.redeemApprovalRate.inner() == 0) {
                continue;
            }

            payoutPoolAmount += _revokeEpochShares(
                poolId,
                shareClassId_,
                payoutAssetId,
                navPerShare,
                valuation,
                poolCurrency,
                epochAmounts_,
                totalIssuance_,
                epochId_
            );
            payoutAssetAmount += epochAmounts_.redeemAssetAmount;
            totalIssuance_ -= epochAmounts_.redeemSharesRevoked;
        }

        totalIssuance[shareClassId_] = totalIssuance_;
        epochPointers[shareClassId_][payoutAssetId].latestRevocation = endEpochId;
        _shareClassNavPerShare[shareClassId_] = navPerShare;
    }

    /// @inheritdoc IShareClassManager
    function claimDeposit(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId)
        external
        returns (uint128 payoutShareAmount, uint128 paymentAssetAmount)
    {
        return claimDepositUntilEpoch(
            poolId, shareClassId_, investor, depositAssetId, epochPointers[shareClassId_][depositAssetId].latestIssuance
        );
    }

    /// @inheritdoc ISingleShareClass
    function claimDepositUntilEpoch(
        PoolId poolId,
        ShareClassId shareClassId_,
        bytes32 investor,
        AssetId depositAssetId,
        uint32 endEpochId
    ) public returns (uint128 payoutShareAmount, uint128 paymentAssetAmount) {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        UserOrder storage userOrder = depositRequest[shareClassId_][depositAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochAmounts storage epochAmounts_ = epochAmounts[shareClassId_][depositAssetId][epochId_];

            // Skip redeem epochs
            if (epochAmounts_.depositApprovalRate.inner() == 0) {
                continue;
            }

            // Skip epoch if user cannot claim
            uint128 approvedAssetAmount = epochAmounts_.depositApprovalRate.mulUint128(userOrder.pending);
            if (approvedAssetAmount == 0) {
                emit ClaimedDeposit(poolId, shareClassId_, epochId_, investor, depositAssetId, 0, userOrder.pending, 0);
                continue;
            }

            uint128 claimableShareAmount = uint256(approvedAssetAmount).mulDiv(
                epochAmounts_.depositSharesIssued, epochAmounts_.depositAssetAmount
            ).toUint128();

            if (claimableShareAmount > 0) {
                userOrder.pending -= approvedAssetAmount;
                payoutShareAmount += claimableShareAmount;
                paymentAssetAmount += approvedAssetAmount;
            } else {
                // Increase pending by approved amount as it did not lead to claimable amount
                pendingDeposit[shareClassId_][depositAssetId] += approvedAssetAmount;
            }

            emit ClaimedDeposit(
                poolId,
                shareClassId_,
                epochId_,
                investor,
                depositAssetId,
                approvedAssetAmount,
                userOrder.pending,
                claimableShareAmount
            );
        }

        userOrder.lastUpdate = endEpochId + 1;
    }

    /// @inheritdoc IShareClassManager
    function claimRedeem(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId)
        external
        returns (uint128 payoutAssetAmount, uint128 paymentShareAmount)
    {
        return claimRedeemUntilEpoch(
            poolId, shareClassId_, investor, payoutAssetId, epochPointers[shareClassId_][payoutAssetId].latestRevocation
        );
    }

    /// @inheritdoc ISingleShareClass
    function claimRedeemUntilEpoch(
        PoolId poolId,
        ShareClassId shareClassId_,
        bytes32 investor,
        AssetId payoutAssetId,
        uint32 endEpochId
    ) public returns (uint128 payoutAssetAmount, uint128 paymentShareAmount) {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        require(endEpochId < epochId[poolId], EpochNotFound());

        UserOrder storage userOrder = redeemRequest[shareClassId_][payoutAssetId][investor];

        for (uint32 epochId_ = userOrder.lastUpdate; epochId_ <= endEpochId; epochId_++) {
            EpochAmounts storage epochAmounts_ = epochAmounts[shareClassId_][payoutAssetId][epochId_];

            // Skip deposit epochs
            if (epochAmounts_.redeemApprovalRate.inner() == 0) {
                continue;
            }

            // Skip epoch if user cannot claim
            uint128 approvedShareAmount = epochAmounts_.redeemApprovalRate.mulUint128(userOrder.pending);
            if (approvedShareAmount == 0) {
                emit ClaimedRedeem(poolId, shareClassId_, epochId_, investor, payoutAssetId, 0, userOrder.pending, 0);
                continue;
            }

            uint128 claimableAssetAmount = uint256(approvedShareAmount).mulDiv(
                epochAmounts_.redeemAssetAmount, epochAmounts_.redeemSharesRevoked
            ).toUint128();

            if (claimableAssetAmount > 0) {
                paymentShareAmount += approvedShareAmount;
                payoutAssetAmount += claimableAssetAmount;
                userOrder.pending -= approvedShareAmount;
            } else {
                // Increase pending by approved amount as it did not lead to claimable amount
                pendingRedeem[shareClassId_][payoutAssetId] += approvedShareAmount;
            }

            emit ClaimedRedeem(
                poolId,
                shareClassId_,
                epochId_,
                investor,
                payoutAssetId,
                approvedShareAmount,
                userOrder.pending,
                claimableAssetAmount
            );
        }

        userOrder.lastUpdate = endEpochId + 1;
    }

    function updateMetadata(PoolId poolId, ShareClassId shareClassId_, string calldata name, string calldata symbol, bytes32 salt, bytes calldata) external auth {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());

        _updateMetadata(shareClassId_, name, symbol, salt);

        emit UpdatedMetadata(poolId, shareClassId_, name, symbol, salt);
    }


    /// @inheritdoc IShareClassManager
    function updateShareClassNav(PoolId poolId, ShareClassId shareClassId_) external view auth returns (D18, uint128) {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function update(PoolId, bytes calldata) external pure {
        revert("unsupported");
    }

    /// @inheritdoc IShareClassManager
    function shareClassNavPerShare(PoolId poolId, ShareClassId shareClassId_)
        external
        view
        returns (D18 navPerShare, uint128 issuance)
    {
        require(shareClassId_ == shareClassId[poolId], ShareClassNotFound());

        return (_shareClassNavPerShare[shareClassId_], totalIssuance[shareClassId_]);
    }

    /// @notice Revokes shares for a single epoch, updates epoch ratio and emits event.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId_ Identifier of the share class
    /// @param payoutAssetId Identifier of the payout asset
    /// @param navPerShare Total value of assets of the pool and share class per share
    /// @param valuation Source of truth for quotas, e.g. the price of a pool amount in payout asset
    /// @param poolCurrency The address of the pool currency
    /// @param epochAmounts_ Epoch ratio storage for the amount of revoked share class tokens and the corresponding
    /// amount
    /// in payout asset
    /// @param totalIssuance_ Total issuance of share class tokens before revoking
    /// @param epochId_ Identifier of the epoch for which we revoke
    /// @return payoutPoolAmount Converted amount of pool currency based on number of revoked shares
    function _revokeEpochShares(
        PoolId poolId,
        ShareClassId shareClassId_,
        AssetId payoutAssetId,
        D18 navPerShare,
        IERC7726 valuation,
        address poolCurrency,
        EpochAmounts storage epochAmounts_,
        uint128 totalIssuance_,
        uint32 epochId_
    ) private returns (uint128 payoutPoolAmount) {
        payoutPoolAmount = navPerShare.mulUint128(epochAmounts_.redeemSharesRevoked);
        epochAmounts_.redeemAssetAmount =
            IERC7726(valuation).getQuote(payoutPoolAmount, poolCurrency, payoutAssetId.addr()).toUint128();

        uint128 nav = navPerShare.mulUint128(totalIssuance_ - epochAmounts_.redeemSharesRevoked);
        emit RevokedShares(
            poolId,
            shareClassId_,
            epochId_,
            navPerShare,
            nav,
            epochAmounts_.redeemSharesRevoked,
            epochAmounts_.redeemAssetAmount
        );
    }

    /// @inheritdoc IShareClassManager
    function exists(PoolId poolId, ShareClassId shareClassId_) public view returns (bool) {
        return shareClassId[poolId] == shareClassId_;
    }

    /// @notice Updates the amount of a request to deposit (exchange) an asset amount for share class tokens.
    ///
    /// @param poolId Identifier of the pool
    /// @param shareClassId_ Identifier of the share class
    /// @param amount Asset token amount which is updated
    /// @param isIncrement Whether the amount is positive or negative
    /// @param investor Address of the entity which is depositing
    /// @param depositAssetId Identifier of the asset which the investor used for their deposit request
    function _updateDepositRequest(
        PoolId poolId,
        ShareClassId shareClassId_,
        uint128 amount,
        bool isIncrement,
        bytes32 investor,
        AssetId depositAssetId
    ) private {
        UserOrder storage userOrder = depositRequest[shareClassId_][depositAssetId][investor];

        // Block updates until pending amount does not impact claimable amount, i.e. last update happened after latest
        // approval
        uint32 latestApproval = epochPointers[shareClassId_][depositAssetId].latestDepositApproval;
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            ClaimDepositRequired()
        );

        userOrder.pending = isIncrement ? userOrder.pending + amount : userOrder.pending - amount;
        userOrder.lastUpdate = epochId[poolId];

        pendingDeposit[shareClassId_][depositAssetId] = isIncrement
            ? pendingDeposit[shareClassId_][depositAssetId] + amount
            : pendingDeposit[shareClassId_][depositAssetId] - amount;

        emit UpdatedDepositRequest(
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
    /// @param isIncrement Whether the amount is positive or negative
    /// @param investor Address of the entity which is depositing
    /// @param payoutAssetId Identifier of the asset which the investor wants to offramp to
    function _updateRedeemRequest(
        PoolId poolId,
        ShareClassId shareClassId_,
        uint128 amount,
        bool isIncrement,
        bytes32 investor,
        AssetId payoutAssetId
    ) private {
        UserOrder storage userOrder = redeemRequest[shareClassId_][payoutAssetId][investor];

        // Block updates until pending amount does not impact claimable amount
        uint32 latestApproval = epochPointers[shareClassId_][payoutAssetId].latestRedeemApproval;
        require(
            userOrder.pending == 0 || latestApproval == 0 || userOrder.lastUpdate > latestApproval,
            ClaimRedeemRequired()
        );

        userOrder.lastUpdate = epochId[poolId];
        userOrder.pending = isIncrement ? userOrder.pending + amount : userOrder.pending - amount;

        pendingRedeem[shareClassId_][payoutAssetId] = isIncrement
            ? pendingRedeem[shareClassId_][payoutAssetId] + amount
            : pendingRedeem[shareClassId_][payoutAssetId] - amount;

        emit UpdatedRedeemRequest(
            poolId,
            shareClassId_,
            epochId[poolId],
            investor,
            payoutAssetId,
            userOrder.pending,
            pendingRedeem[shareClassId_][payoutAssetId]
        );
    }

    function _updateMetadata(ShareClassId shareClassId_, string calldata name, string calldata symbol, bytes32 salt) private {
        uint256 nLen = bytes(name).length;
        require(nLen> 0 && nLen <= 128, InvalidMetadataName());

        uint256 sLen = bytes(symbol).length;
        require(sLen > 0 && sLen <= 32, InvalidMetadataSymbol());

        // Either the salt has not changed, or the salt was never used before by any share class token
        require(salt == metadata[shareClassId_].salt || !salts[salt], AlreadyUsedSalt());
        salts[salt] = true;

        metadata[shareClassId_] = ShareClassMetadata(name, symbol, salt);

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

            emit NewEpoch(poolId, newEpochId);

            return epochId_;
        } else {
            return uint32(uint128(epochId_ - 1).max(1));
        }
    }
}

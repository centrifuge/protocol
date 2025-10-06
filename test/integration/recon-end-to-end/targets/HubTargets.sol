// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {Hub} from "src/core/hub/Hub.sol";
import {IHubHandler} from "src/core/hub/interfaces/IHubHandler.sol";
import {IShareClassManager} from "src/core/hub/interfaces/IShareClassManager.sol";
import {IHubRequestManager} from "src/core/hub/interfaces/IHubRequestManager.sol";
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId, newAssetId} from "src/core/types/AssetId.sol";
import {PoolId, newPoolId} from "src/core/types/PoolId.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MAX_MESSAGE_COST} from "src/core/messaging/interfaces/IGasService.sol";
import {RequestCallbackMessageLib} from "src/vaults/libraries/RequestCallbackMessageLib.sol";
import {IHubMessageSender} from "src/core/interfaces/IGatewaySenders.sol";

// Test Utils
import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";

abstract contract HubTargets is BaseTargetFunctions, Properties {
    // ═══════════════════════════════════════════════════════════════
    // TARGET FUNCTIONS - Public entry points for invariant testing
    // ═══════════════════════════════════════════════════════════════
    uint128 constant GAS = MAX_MESSAGE_COST;

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    // NOTE: this notifies for all epochs until all have been claimed
    function hub_notifyDeposit_clamped(
        uint32 maxClaims
    ) public updateGhostsWithType(OpType.NOTIFY) asActor {
        // Setup vault context and investor
        bytes32 investor = CastLib.toBytes32(_getActor());
        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;

        // Calculate and bound max claims
        uint32 maxClaimsBound = batchRequestManager.maxDepositClaims(
            poolId,
            scId,
            investor,
            assetId
        );
        maxClaims = uint32(between(maxClaims, 0, maxClaimsBound));

        // Capture validation state if needed
        bool hasClaimedAll = _hasClaimedAllEpochs(maxClaims, maxClaimsBound);
        uint128 pendingBeforeSCM;
        uint256 maxMintBefore;
        if (hasClaimedAll) {
            (pendingBeforeSCM, , maxMintBefore) = _captureDepositStateBefore(
                investor
            );
        }

        // Handle validation or continuation
        if (maxClaimsBound > 0) {
            // Continue claiming remaining epochs
            hub_notifyDeposit(1);
        }
    }

    // NOTE: this notifies for all epochs until all have been claimed
    function hub_notifyRedeem_clamped(
        uint32 maxClaims
    ) public updateGhostsWithType(OpType.NOTIFY) asActor {
        // Setup vault context and investor
        bytes32 investor = CastLib.toBytes32(_getActor());
        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;

        // Calculate and bound max claims
        uint32 maxClaimsBound = batchRequestManager.maxRedeemClaims(
            poolId,
            scId,
            investor,
            assetId
        );
        maxClaims = uint32(between(maxClaims, 0, maxClaimsBound));

        // Capture state for ghost variables
        address actor = _getActor();
        uint256 investorClaimableBefore = asyncRequestManager.maxWithdraw(
            _getVault(),
            actor
        );

        // Handle validation or continuation
        if (maxClaimsBound > 0) {
            // Continue claiming remaining epochs
            hub_notifyRedeem(1);
        }
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // ═══════════════════════════════════════════════════════════════
    // PERMISSIONLESS FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    function hub_createPool(
        uint64 poolIdAsUint,
        address admin,
        uint128 assetIdAsUint
    ) public updateGhosts asActor returns (PoolId poolId) {
        PoolId _poolId = PoolId.wrap(poolIdAsUint);
        AssetId _assetId = AssetId.wrap(assetIdAsUint);

        hub.createPool(_poolId, admin, _assetId);

        _addPool(_poolId.raw());

        return _poolId;
    }

    function hub_createPool_clamped(
        uint64 poolIdAsUint,
        uint128 assetEntropy
    ) public asActor returns (PoolId /* poolId */) {
        AssetId _assetId = Helpers.getRandomAssetId(
            createdAssetIds,
            assetEntropy
        );

        hub_createPool(poolIdAsUint, _getActor(), _assetId.raw());
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier
    /// @dev Property: After successfully calling claimDeposit for an investor (via notifyDeposit), their
    /// depositRequest[..].lastUpdate equals the nowDepositEpoch for the deposit
    ///
    /// @notice Deposit Flow Tracking:
    /// - Tracks AsyncRequestManager pending deltas (pendingBeforeARM - pendingAfterARM)
    /// - Tracks maxMint changes for symmetry with redeem flow
    /// - Uses hubHandler.notifyDeposit() return values for reliable state tracking
    /// - Updates ghost variables: sumOfFulfilledDeposits, sumOfClaimedDeposits, userDepositProcessed
    function hub_notifyDeposit(
        uint32 maxClaims
    ) public updateGhostsWithType(OpType.NOTIFY) asActor {
        // Setup vault context and investor
        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;
        bytes32 investor = CastLib.toBytes32(_getActor());

        // Calculate max claims
        uint32 maxClaimsBound = batchRequestManager.maxDepositClaims(
            poolId,
            scId,
            investor,
            assetId
        );

        // Capture validation state if needed
        bool hasClaimedAll = _hasClaimedAllEpochs(maxClaims, maxClaimsBound);
        uint128 pendingBeforeSCM;
        uint256 maxMintBefore;
        if (hasClaimedAll) {
            (pendingBeforeSCM, , maxMintBefore) = _captureDepositStateBefore(
                CastLib.toBytes32(_getActor())
            );
        }

        // Capture state for ghost variables
        (, , , , uint128 pendingBeforeARM, , , , , ) = asyncRequestManager
            .investments(_getVault(), _getActor());

        // NOTE: actually makes the call to the target function
        // TODO(wischli): Implement event-based approach for notifyDeposit (see Properties.sol)
        vm.prank(_getActor());
        batchRequestManager.notifyDeposit(
            poolId,
            scId,
            assetId,
            investor,
            maxClaims,
            _getActor()
        );

        // TODO(wischli): Parse ClaimDeposit events to get actual values
        uint128 totalPayoutShareAmount = 0;
        uint128 totalPaymentAssetAmount = 0;
        uint128 cancelledAssetAmount = 0;

        _executeSendRequestCallback(
            CastLib.toBytes32(_getActor()),
            totalPaymentAssetAmount,
            totalPayoutShareAmount,
            cancelledAssetAmount
        );

        _updateDepositGhostVariables(
            pendingBeforeARM,
            totalPayoutShareAmount,
            totalPaymentAssetAmount,
            cancelledAssetAmount
        );

        // Handle validation
        if (hasClaimedAll) {
            _validateDepositClaimComplete(
                CastLib.toBytes32(_getActor()),
                pendingBeforeSCM,
                maxMintBefore,
                totalPaymentAssetAmount
            );
        }
    }

    /// @dev Property: After successfully claimRedeem for an investor (via notifyRedeem), their
    /// redeemRequest[..].lastUpdate equals the nowRedeemEpoch for the redemption
    ///
    /// @notice Redeem Flow Tracking:
    /// - Tracks claimable withdrawal deltas (investorClaimableAfter - investorClaimableBefore)
    /// - Tracks share balance changes (investorSharesBefore vs investorSharesAfter)
    /// - Uses hubHandler.notifyRedeem() return values for reliable state tracking
    /// - Updates ghost variables: sumOfWithdrawable, userRedemptionsProcessed, userCancelledRedeems
    function hub_notifyRedeem(
        uint32 maxClaims
    ) public updateGhostsWithType(OpType.NOTIFY) asActor {
        // Setup vault context and investor
        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;
        bytes32 investor = CastLib.toBytes32(_getActor());

        // Calculate max claims
        uint32 maxClaimsBound = batchRequestManager.maxRedeemClaims(
            poolId,
            scId,
            investor,
            assetId
        );

        // Capture state for ghost variables
        uint256 investorClaimableBefore = asyncRequestManager.maxWithdraw(
            _getVault(),
            _getActor()
        );

        // NOTE: actually makes the call to the target function
        // TODO(wischli): Implement event-based approach for notifyRedeem (see Properties.sol)
        vm.prank(_getActor());
        batchRequestManager.notifyRedeem(
            poolId,
            scId,
            assetId,
            investor,
            maxClaims,
            _getActor()
        );

        // TODO(wischli): Parse ClaimRedeem events to get actual values
        uint128 payoutAssetAmount = 0;
        uint128 paymentShareAmount = 0;
        uint128 cancelledShareAmount = 0;

        _executeSendRedeemCallback(
            CastLib.toBytes32(_getActor()),
            payoutAssetAmount,
            paymentShareAmount,
            cancelledShareAmount
        );

        _updateRedeemGhostVariables(
            investorClaimableBefore,
            asyncRequestManager.maxWithdraw(_getVault(), _getActor()),
            paymentShareAmount,
            cancelledShareAmount
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // EXECUTION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Multicall is publicly exposed without access protections so can be called by anyone
    function hub_multicall(
        bytes[] memory data
    ) public payable updateGhostsWithType(OpType.BATCH) asActor {
        hub.multicall{value: msg.value}(data);
    }

    /// @dev Makes a call directly to the unclamped handler so doesn't include asActor modifier or else would cause
    /// errors with foundry testing
    function hub_multicall_clamped() public payable {
        this.hub_multicall{value: msg.value}(queuedCalls);

        queuedCalls = new bytes[](0);
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════
    function hub_setRequestManager(
        uint64 poolId,
        bytes16 shareClassId,
        uint128 assetId,
        address requestManager
    ) public asAdmin {
        // New signature: hub.setRequestManager(poolId, centrifugeId, hubManager, spokeManager, refund)
        hub.setRequestManager{value: GAS}(
            PoolId.wrap(poolId),
            CENTRIFUGE_CHAIN_ID,
            IHubRequestManager(address(batchRequestManager)),
            CastLib.toBytes32(requestManager),
            _getActor()
        );
    }

    function hub_updateBalanceSheetManager(
        uint16 chainId,
        uint64 poolId,
        address manager,
        bool enable
    ) public asAdmin {
        hub.updateBalanceSheetManager{value: GAS}(
            PoolId.wrap(poolId),
            chainId,
            CastLib.toBytes32(manager),
            enable,
            address(this)
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Helper to determine if all available epochs have been claimed
    /// @param maxClaims Number of claims to process
    /// @param maxClaimsBound Maximum claims allowed
    /// @return True if all epochs have been claimed
    function _hasClaimedAllEpochs(
        uint32 maxClaims,
        uint32 maxClaimsBound
    ) private pure returns (bool) {
        return maxClaims == maxClaimsBound && maxClaims > 0;
    }

    // ═══════════════════════════════════════════════════════════════
    // STATE CAPTURE FUNCTIONS - Before/after state tracking
    // ═══════════════════════════════════════════════════════════════

    /// @return pendingBeforeSCM Pending deposit amount in ShareClassManager
    /// @return pendingBeforeARM Pending deposit amount in AsyncRequestManager
    /// @return maxMintBefore Maximum mint capacity before claim
    function _captureDepositStateBefore(
        bytes32 investor
    )
        private
        view
        returns (
            uint128 pendingBeforeSCM,
            uint128 pendingBeforeARM,
            uint256 maxMintBefore
        )
    {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;

        (pendingBeforeSCM, ) = batchRequestManager.depositRequest(
            poolId,
            scId,
            assetId,
            investor
        );
        (, , , , pendingBeforeARM, , , , , ) = asyncRequestManager.investments(
            vault,
            _getActor()
        );
        maxMintBefore = asyncRequestManager.maxMint(vault, _getActor());
    }

    // ═══════════════════════════════════════════════════════════════
    // GHOST VARIABLE UPDATES - Tracking for invariant properties
    // ═══════════════════════════════════════════════════════════════

    /// @dev Updates all ghost variables after deposit claim
    /// @param pendingBeforeARM Pending amount in AsyncRequestManger before claim
    /// @param totalPayoutShareAmount Total shares paid out from claim
    /// @param totalPaymentAssetAmount Total assets used for payment
    /// @param cancelledAssetAmount Amount of assets cancelled
    function _updateDepositGhostVariables(
        uint128 pendingBeforeARM,
        uint128 totalPayoutShareAmount,
        uint128 totalPaymentAssetAmount,
        uint128 cancelledAssetAmount
    ) private {
        IBaseVault vault = _getVault();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;
        ShareClassId scId = vault.scId();
        address actor = _getActor();

        (, , , , uint128 pendingAfterARM, , , , , ) = asyncRequestManager
            .investments(vault, actor);

        if (pendingBeforeARM >= pendingAfterARM) {
            sumOfFulfilledDeposits[vault.share()] += (pendingBeforeARM -
                pendingAfterARM);
        }

        sumOfClaimedDeposits[vault.share()] += totalPayoutShareAmount;
        userDepositProcessed[scId][assetId][actor] += totalPaymentAssetAmount;
        userCancelledDeposits[scId][assetId][actor] += cancelledAssetAmount;
        sumOfClaimedCancelledDeposits[vault.asset()] += cancelledAssetAmount;
    }

    // ═══════════════════════════════════════════════════════════════
    // VALIDATION FUNCTIONS - Assertion checks
    // ═══════════════════════════════════════════════════════════════

    /// @dev Validates deposit claim completion when all epochs are claimed
    /// @param investor The investor's address as bytes32
    /// @param pendingBeforeSCM Pending amount in SCM before claim
    /// @param maxMintBefore Maximum mint capacity before claim
    /// @param totalPaymentAssetAmount Total assets used for payment
    function _validateDepositClaimComplete(
        bytes32 investor,
        uint128 pendingBeforeSCM,
        uint256 maxMintBefore,
        uint128 totalPaymentAssetAmount
    ) private {
        IBaseVault vault = _getVault();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        (uint128 pendingAfterSCM, uint32 lastUpdate) = batchRequestManager
            .depositRequest(poolId, scId, assetId, investor);
        (uint32 depositEpochId, , , ) = batchRequestManager.epochId(
            poolId,
            scId,
            assetId
        );
        (bool isCancellingAfter, ) = batchRequestManager.queuedDepositRequest(
            poolId,
            scId,
            assetId,
            investor
        );
        uint256 maxMintAfter = asyncRequestManager.maxMint(vault, _getActor());

        eq(lastUpdate, depositEpochId + 1, "lastUpdate != nowDepositEpoch");

        t(
            !isCancellingAfter,
            "queued cancellation post claiming should not be possible"
        );

        uint128 pendingDelta = pendingBeforeSCM >= pendingAfterSCM
            ? pendingBeforeSCM - pendingAfterSCM
            : 0;
        gte(
            pendingDelta,
            totalPaymentAssetAmount,
            "pending delta should be greater (if cancel queued) or equal to the payment asset amount"
        );

        uint256 expectedMaxMint = maxMintBefore >= totalPaymentAssetAmount
            ? maxMintBefore - totalPaymentAssetAmount
            : 0;
        gte(
            maxMintAfter,
            expectedMaxMint,
            "maxMint should decrease by at most the payment asset amount after claiming"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // EXECUTION HELPERS - Core logic for notify operations
    // ═══════════════════════════════════════════════════════════════

    /// @dev Executes redeem claim with accurate cancellation tracking
    /// @notice Replicates Hub.sol logic: processes claims then sends callback
    /// @param investor The investor's address as bytes32
    /// @param totalPaymentAssetAmount Amount of assets used for payment
    /// @param totalPayoutShareAmount Amount of shares paid out
    /// @param cancelledAssetAmount Amount of assets cancelled (accurate)
    function _executeSendRequestCallback(
        bytes32 investor,
        uint128 totalPaymentAssetAmount,
        uint128 totalPayoutShareAmount,
        uint128 cancelledAssetAmount
    ) private {
        // Replicate Hub's callback sending logic
        if (totalPaymentAssetAmount > 0 || cancelledAssetAmount > 0) {
            bytes memory message = RequestCallbackMessageLib.serialize(
                RequestCallbackMessageLib.FulfilledDepositRequest({
                    investor: investor,
                    fulfilledAssetAmount: totalPaymentAssetAmount,
                    fulfilledShareAmount: totalPayoutShareAmount,
                    cancelledAssetAmount: cancelledAssetAmount
                })
            );

            hub.sender().sendRequestCallback{value: GAS}(
                _getVault().poolId(),
                _getVault().scId(),
                vaultRegistry.vaultDetails(_getVault()).assetId,
                message,
                0, // extraGasLimit
                address(this) // refund
            );
        }
    }

    /// @dev Executes redeem callback sending logic
    /// @notice Replicates Hub.sol logic for redeem callbacks
    /// @param investor The investor's address as bytes32
    /// @param payoutAssetAmount Amount of assets paid out
    /// @param paymentShareAmount Amount of shares used for payment
    /// @param cancelledShareAmount Amount of shares cancelled
    function _executeSendRedeemCallback(
        bytes32 investor,
        uint128 payoutAssetAmount,
        uint128 paymentShareAmount,
        uint128 cancelledShareAmount
    ) private {
        // Replicate Hub's callback sending logic
        if (paymentShareAmount > 0 || cancelledShareAmount > 0) {
            bytes memory message = RequestCallbackMessageLib.serialize(
                RequestCallbackMessageLib.FulfilledRedeemRequest({
                    investor: investor,
                    fulfilledAssetAmount: payoutAssetAmount,
                    fulfilledShareAmount: paymentShareAmount,
                    cancelledShareAmount: cancelledShareAmount
                })
            );

            hub.sender().sendRequestCallback{value: GAS}(
                _getVault().poolId(),
                _getVault().scId(),
                vaultRegistry.vaultDetails(_getVault()).assetId,
                message,
                0, // extraGasLimit
                address(this) // refund
            );
        }
    }

    /// @dev Updates all ghost variables after redeem claim
    /// @param investorClaimableBefore Claimable amount before claim
    /// @param investorClaimableAfter Claimable amount after claim
    /// @param paymentShareAmount Total shares used for payment
    /// @param cancelledShareAmount Amount of shares cancelled
    function _updateRedeemGhostVariables(
        uint256 investorClaimableBefore,
        uint256 investorClaimableAfter,
        uint128 paymentShareAmount,
        uint128 cancelledShareAmount
    ) private {
        IBaseVault vault = _getVault();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;
        ShareClassId scId = vault.scId();
        address actor = _getActor();

        if (investorClaimableAfter >= investorClaimableBefore) {
            sumOfWithdrawable[vault.asset()] += (investorClaimableAfter -
                investorClaimableBefore);
        }

        userRedemptionsProcessed[scId][assetId][actor] += paymentShareAmount;

        userCancelledRedeems[scId][assetId][actor] += cancelledShareAmount;
        sumOfClaimedCancelledRedeemShares[
            vault.share()
        ] += cancelledShareAmount;
    }

    /// @dev Executes redeem claim with accurate cancellation tracking
    /// @notice Replicates Hub.sol logic: processes claims then sends callback
    /// @param investor The investor's address as bytes32
    /// @param maxClaims Maximum claims to process
    /// @return paymentShareAmount Amount of shares used for payment
    /// @return payoutAssetAmount Amount of assets paid out
    /// @return cancelledShareAmount Amount of shares cancelled (accurate)
    function _executeNotifyRedeem(
        bytes32 investor,
        uint32 maxClaims
    )
        private
        returns (
            uint128 paymentShareAmount,
            uint128 payoutAssetAmount,
            uint128 cancelledShareAmount
        )
    {
        IBaseVault vault = _getVault();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // TODO(wischli): Implement event-based approach for notifyRedeem (see Properties.sol)
        batchRequestManager.notifyRedeem(
            poolId,
            scId,
            assetId,
            investor,
            maxClaims,
            msg.sender
        );

        // TODO(wischli): Parse ClaimRedeem events to get actual values
        payoutAssetAmount = 0;
        paymentShareAmount = 0;
        cancelledShareAmount = 0;

        // Replicate Hub's callback sending logic
        if (paymentShareAmount > 0 || cancelledShareAmount > 0) {
            bytes memory message = RequestCallbackMessageLib.serialize(
                RequestCallbackMessageLib.FulfilledRedeemRequest({
                    investor: investor,
                    fulfilledAssetAmount: payoutAssetAmount,
                    fulfilledShareAmount: paymentShareAmount,
                    cancelledShareAmount: cancelledShareAmount
                })
            );

            hub.sender().sendRequestCallback{value: GAS}(
                poolId,
                scId,
                assetId,
                message,
                0, // extraGasLimit
                msg.sender // refund
            );
        }

        return (paymentShareAmount, payoutAssetAmount, cancelledShareAmount);
    }
}

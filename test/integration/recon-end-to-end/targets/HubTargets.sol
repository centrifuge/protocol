// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {Hub} from "src/hub/Hub.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Test Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";

abstract contract HubTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    /// === Permissionless Functions === ///
    function hub_createPool(uint64 poolIdAsUint, address admin, uint128 assetIdAsUint)
        public
        updateGhosts
        asActor
        returns (PoolId poolId)
    {
        PoolId _poolId = PoolId.wrap(poolIdAsUint);
        AssetId _assetId = AssetId.wrap(assetIdAsUint);

        hub.createPool(_poolId, admin, _assetId);

        _addPool(_poolId.raw());

        return _poolId;
    }

    function hub_createPool_clamped(uint64 poolIdAsUint, uint128 assetEntropy) public asActor returns (PoolId poolId) {
        AssetId _assetId = Helpers.getRandomAssetId(createdAssetIds, assetEntropy);

        hub_createPool(poolIdAsUint, _getActor(), _assetId.raw());
    }

    /// @dev The investor is explicitly clamped to one of the actors to make checking properties over all actors easier
    /// @dev Property: After successfully calling claimDeposit for an investor (via notifyDeposit), their
    /// depositRequest[..].lastUpdate equals the nowDepositEpoch for the redeem
    function hub_notifyDeposit(uint32 maxClaims) public updateGhostsWithType(OpType.NOTIFY) asActor {
        bytes32 investor = CastLib.toBytes32(_getActor());
        uint32 maxClaimsBound = shareClassManager.maxDepositClaims(
            IBaseVault(_getVault()).scId(), investor, hubRegistry.currency(IBaseVault(_getVault()).poolId())
        );
        maxClaims = uint32(between(maxClaims, 0, maxClaimsBound));

        (uint128 pendingBeforeSCM,) = shareClassManager.depositRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );
        (,,,, uint128 pendingBeforeARM,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        (, uint128 cancelledAmountBefore) = shareClassManager.queuedDepositRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );

        hub.notifyDeposit(
            IBaseVault(_getVault()).poolId(),
            IBaseVault(_getVault()).scId(),
            hubRegistry.currency(IBaseVault(_getVault()).poolId()),
            investor,
            maxClaims
        );

        (uint128 pendingAfterSCM, uint32 lastUpdate) = shareClassManager.depositRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );
        (,,,, uint128 pendingAfterARM,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        (uint32 depositEpochId,,,) = shareClassManager.epochId(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
        );
        (, uint128 cancelledAmountAfter) = shareClassManager.queuedDepositRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );

        uint128 cancelDelta = cancelledAmountBefore - cancelledAmountAfter; // cancelled decreases if it was claimed
        sumOfFullfilledDeposits[IBaseVault(_getVault()).share()] += (pendingBeforeARM - pendingAfterARM); // fulfillments
            // are handled in the AsyncRequestManager
        sumOfClaimedDeposits[IBaseVault(_getVault()).share()] += (pendingBeforeSCM - pendingAfterSCM); // claims are
            // handled in the ShareClassManager
        depositProcessed[IBaseVault(_getVault()).scId()][hubRegistry.currency(IBaseVault(_getVault()).poolId())][_getActor(
        )] += (pendingBeforeSCM - pendingAfterSCM);
        cancelledDeposits[IBaseVault(_getVault()).scId()][hubRegistry.currency(IBaseVault(_getVault()).poolId())][_getActor(
        )] += cancelDelta;

        // precondition: lastUpdate doesn't change if there's no claim actually made
        if (maxClaims == maxClaimsBound && maxClaims > 0) {
            // nowDepositEpoch = depositEpochId + 1
            eq(lastUpdate, depositEpochId + 1, "lastUpdate != nowDepositEpoch1");
        } else if (maxClaimsBound > 0) {
            // Continue claiming until all epochs are processed
            hub_notifyDeposit(1);
        }
    }

    /// @dev Property: After successfully claimRedeem for an investor (via notifyRedeem), their
    /// depositRequest[..].lastUpdate equals the nowRedeemEpoch for the redemption
    function hub_notifyRedeem(uint32 maxClaims) public updateGhostsWithType(OpType.NOTIFY) asActor {
        bytes32 investor = CastLib.toBytes32(_getActor());
        uint32 maxClaimsBound = shareClassManager.maxRedeemClaims(
            IBaseVault(_getVault()).scId(), investor, hubRegistry.currency(IBaseVault(_getVault()).poolId())
        );
        maxClaims = uint32(between(maxClaims, 0, maxClaimsBound));

        uint256 investorSharesBefore = IShareToken(IBaseVault(_getVault()).share()).balanceOf(_getActor());
        uint256 investorClaimableBefore = asyncRequestManager.maxWithdraw(IBaseVault(_getVault()), _getActor());
        (, uint128 cancelledAmountBefore) = shareClassManager.queuedRedeemRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );
        (uint128 pendingBefore,) = shareClassManager.redeemRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );

        hub.notifyRedeem(
            IBaseVault(_getVault()).poolId(),
            IBaseVault(_getVault()).scId(),
            hubRegistry.currency(IBaseVault(_getVault()).poolId()),
            investor,
            maxClaims
        );

        (uint128 pendingAfter, uint32 lastUpdate) = shareClassManager.redeemRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );
        (, uint32 redeemEpochId,,) = shareClassManager.epochId(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId())
        );
        (, uint128 cancelledAmountAfter) = shareClassManager.queuedRedeemRequest(
            IBaseVault(_getVault()).scId(), hubRegistry.currency(IBaseVault(_getVault()).poolId()), investor
        );

        uint256 investorSharesAfter = IShareToken(IBaseVault(_getVault()).share()).balanceOf(_getActor());
        uint256 investorClaimableAfter = asyncRequestManager.maxWithdraw(IBaseVault(_getVault()), _getActor());

        uint128 cancelDelta = cancelledAmountBefore - cancelledAmountAfter; // cancelled decreases if it was claimed
        currencyPayout[IBaseVault(_getVault()).asset()] += (investorClaimableAfter - investorClaimableBefore); // the
            // currency payout is returned by SCM::notifyRedeem and stored in user's investments in AsyncRequestManager
        cancelRedeemShareTokenPayout[IBaseVault(_getVault()).share()] += cancelDelta;
        redemptionsProcessed[IBaseVault(_getVault()).scId()][hubRegistry.currency(IBaseVault(_getVault()).poolId())][_getActor(
        )] += (pendingBefore - pendingAfter);
        cancelledRedemptions[IBaseVault(_getVault()).scId()][hubRegistry.currency(IBaseVault(_getVault()).poolId())][_getActor(
        )] += cancelDelta;
        sumOfClaimedRedeemCancelations[IBaseVault(_getVault()).share()] += cancelDelta;

        // precondition: lastUpdate doesn't change if there's no claim actually made
        if (maxClaims == maxClaimsBound && maxClaims > 0) {
            // nowRedeemEpoch = redeemEpochId + 1
            eq(lastUpdate, redeemEpochId + 1, "lastUpdate != nowRedeemEpoch");
        } else if (maxClaimsBound > 0) {
            // Continue claiming until all epochs are processed
            hub_notifyRedeem(1);
        }
    }

    /// === EXECUTION FUNCTIONS === ///

    /// @dev Multicall is publicly exposed without access protections so can be called by anyone
    function hub_multicall(bytes[] memory data) public payable updateGhostsWithType(OpType.BATCH) asActor {
        hub.multicall{value: msg.value}(data);
    }

    /// @dev Makes a call directly to the unclamped handler so doesn't include asActor modifier or else would cause
    /// errors with foundry testing
    function hub_multicall_clamped() public payable {
        this.hub_multicall{value: msg.value}(queuedCalls);

        queuedCalls = new bytes[](0);
    }
}

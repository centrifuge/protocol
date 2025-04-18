// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {console2} from "forge-std/console2.sol";

// Libraries
import {MathLib} from "src/misc/libraries/MathLib.sol";

// Interfaces
import {AccountType} from "src/hub/interfaces/IHub.sol";

// Types
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {AccountId} from "src/common/types/AccountId.sol";

// Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {OpType} from "./BaseBeforeAfter.sol";
import {BeforeAfter} from "./BeforeAfter.sol";
import {BaseBeforeAfter} from "./BaseBeforeAfter.sol";
import {HubPropertiesBase} from "./HubPropertiesBase.sol";
import {Setup} from "./Setup.sol";

abstract contract Properties is HubPropertiesBase, Setup {
    using MathLib for D18;
    using MathLib for uint128;
    using MathLib for uint256;

    modifier stateless override {
        _;
        revert("stateless");
    }

    /// === Canaries === ///

    /// === Global Properties === ///

    // NOTE: these are commented out because they don't actually get reset after calls, only when there's a call to unlock or a new tx
    // function property_debited_transient_reset() public {
    //     eq(_after.ghostDebited, 0, "debited not reset");
    // }

    // function property_credited_transient_reset() public {
    //     eq(_after.ghostCredited, 0, "credited not reset");
    // }

    /// @dev Property: The total pending asset amount pendingDeposit[..] is always >= the approved asset amount epochAmounts[..].depositApproved
    function property_total_pending_and_approved() public  {
        property_total_pending_and_approved(shareClassManager, hubRegistry, createdPools);
    }

    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the sum of pending user redeem amounts redeemRequest[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount epochAmounts[..].redeemRevokedShares
    // TODO: come back to this to check if accounting for case is correct
    function property_total_pending_redeem_geq_sum_pending_user_redeem() public {
        property_total_pending_redeem_geq_sum_pending_user_redeem(shareClassManager, hubRegistry, createdPools, _getActors());
    }

    /// @dev Property: The current pool epochId is always strictly greater than any latest pointer of epochPointers[...]
    function property_epochId_strictly_greater_than_any_latest_pointer() public {
        property_epochId_strictly_greater_than_any_latest_pointer(shareClassManager, hubRegistry, createdPools);
    }

    /// @dev Property: The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. multicall/execute) independent of the number of approvals
    function property_epochId_can_increase_by_one_within_same_transaction() public {
        property_epochId_can_increase_by_one_within_same_transaction(createdPools);
    }

    /// @dev Property:  account.totalDebit and account.totalCredit is always less than uint128(type(int128).max)
    function property_account_totalDebit_and_totalCredit_leq_max_int128() public  {
        property_account_totalDebit_and_totalCredit_leq_max_int128(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    }

    /// @dev Property: Any decrease in valuation should not result in an increase in accountValue
    function property_decrease_valuation_no_increase_in_accountValue() public  {
        property_decrease_valuation_no_increase_in_accountValue(shareClassManager, hubRegistry, holdings, createdPools);
    }

    /// @dev Property: Value of Holdings == accountValue(Asset)
    function property_accounting_and_holdings_soundness() public  {
        property_accounting_and_holdings_soundness(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    }

    /// @dev Property: Total Yield = assets - equity
    function property_total_yield() public  {
        property_total_yield(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    }

    /// @dev Property: assets = equity + gain + loss
    function property_asset_soundness() public  {
        property_asset_soundness(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    }

    /// @dev Property: equity = assets - loss - gain
    function property_equity_soundness() public  {
        property_equity_soundness(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    }

    /// @dev Property: gain = totalYield + loss
    function property_gain_soundness() public  {
        property_gain_soundness(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    }

    /// @dev Property: loss = totalYield - gain
    function property_loss_soundness() public  {
        property_loss_soundness(shareClassManager, hubRegistry, holdings, accounting, createdPools);
    } 

    /// @dev Property: A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval pointer epochPointers[..].latestRedeemApproval
    function property_user_cannot_mutate_pending_redeem() public  {
        property_user_cannot_mutate_pending_redeem(shareClassManager, hubRegistry, createdPools, _getActors());
    }

    /// @dev Property: After FM performs approveDeposits and revokeShares with non-zero navPerShare, the total issuance totalIssuance[..] is increased
    /// @dev WIP, this may not be possible to prove because these calls are made via execute which makes determining the before and after state difficult
    // function property_total_issuance_increased_after_approve_deposits_and_revoke_shares() public {
        
    //     bool hasApprovedDeposits = false;
    //     bool hasRevokedShares = false;
    //     for(uint256 i = 0; i < queuedOps.length; i++) {
    //         QueuedOp queuedOp = queuedOps[i];
    //         if(queuedOp.op == Op.APPROVE_DEPOSITS) {
    //             hasApprovedDeposits = true;
    //         }

    //         // there has to have been an approveDeposits call before a revokeShares call
    //         if(queuedOp.op == Op.REVOKE_SHARES && hasApprovedDeposits) {
    //             hasRevokedShares = true;
    //         }
    //     }

    //     // if(hasApprovedDeposits && hasRevokedShares) {
    //     //     shareClassManager.metrics(scId);
    //     // }
    // }


    /// Stateless Properties ///

    /// @dev Property: The sum of eligible user payoutShareAmount for an epoch is <= the number of issued shares epochAmounts[..].depositShares
    /// @dev Property: The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset amount epochAmounts[..].depositPool
    /// @dev Stateless because of the calls to claimDeposit which would make story difficult to read
    function property_eligible_user_deposit_amount_leq_deposit_issued_amount() public  {
        property_eligible_user_deposit_amount_leq_deposit_issued_amount(shareClassManager, hubRegistry, createdPools, _getActors());
    }

    /// @dev Property: The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset amount epochAmounts[..].redeemApproved
    /// @dev Property: The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share amount epochAmounts[..].redeemAssets
    /// @dev This doesn't sum over previous epochs because it can be assumed that it'll be called by the fuzzer for each current epoch
    function property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount() public  {
        property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount(shareClassManager, hubRegistry, createdPools, _getActors());
    }

    /// @dev Property: The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to the balance of the escrow for said pool-shareClass for the respective token
    // TODO: verify if this should be applied to the vaults side instead
    // function property_holdings_balance_equals_escrow_balance() public stateless {
    //     address[] memory _actors = _getActors();

    //     for (uint256 i = 0; i < createdPools.length; i++) {
    //         PoolId poolId = createdPools[i];
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);

    //             (uint128 holdingAssetAmount,,,) = holdings.holding(poolId, scId, assetId);
                
    //             address pendingShareClassEscrow = hub.escrow(poolId, scId, EscrowId.PendingShareClass);
    //             address shareClassEscrow = hub.escrow(poolId, scId, EscrowId.ShareClass);
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow, assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());
                
    //             eq(holdingAssetAmount, pendingShareClassEscrowBalance + shareClassEscrowBalance, "holding != escrow balance");
    //         }
    //     }
    // }

    /// @dev Property: The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the associated token in the escrow
    // TODO: confirm if this is correct because it seems like AssetRegistry would never be receiving tokens in the first place
    // TODO: verify if this should be applied to the vaults side instead
    // function property_assetRegistry_balance_leq_escrow_balance() public stateless {
    //     address[] memory _actors = _getActors();

    //     for (uint256 i = 0; i < createdPools.length; i++) {
    //         PoolId poolId = createdPools[i];
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);

    //             address pendingShareClassEscrow = hub.escrow(poolId, scId, EscrowId.PendingShareClass);
    //             address shareClassEscrow = hub.escrow(poolId, scId, EscrowId.ShareClass);
    //             uint256 assetRegistryBalance = assetRegistry.balanceOf(address(assetRegistry), assetId.raw());
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow, assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());

    //             lte(assetRegistryBalance, pendingShareClassEscrowBalance + shareClassEscrowBalance, "assetRegistry balance > escrow balance");
    //         }
    //     }
    // }

    /// Rounding Properties /// 

    /// @dev Property: Checks that rounding error is within acceptable bounds (1000 wei)
    /// @dev Simulates the operation in the MultiShareClass::_revokeEpochShares function
    function property_MulUint128Rounding(D18 navPerShare, uint128 amount) public override {
        property_MulUint128Rounding(navPerShare, amount);
    }

    /// @dev Property: Checks that rounding error is within acceptable bounds (1e6 wei) for very small numbers
    /// @dev Simulates the operation in the MultiShareClass::_revokeEpochShares function
    function property_MulUint128EdgeCases(D18 navPerShare, uint128 amount) public override {
        property_MulUint128EdgeCases(navPerShare, amount);
    }
}
// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Asserts} from "@chimera/Asserts.sol";
import {console2} from "forge-std/console2.sol";

// Libraries
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
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
import {BeforeAfter, OpType} from "./BeforeAfter.sol";

abstract contract Properties is BeforeAfter, Asserts {
    using MathLib for D18;
    using MathLib for uint128;
    using MathLib for uint256;

    /// === Canaries === ///

    /// === Global Properties === ///

    /// @dev Property: The total pending asset amount pendingDeposit[..] is always >= the approved asset
    /// epochInvestAmounts[..].approvedAssetAmount
    function property_total_pending_and_approved() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 depositEpochId,,,) = shareClassManager.epochId(scId, assetId);
                uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);
                (uint128 pendingAssetAmount, uint128 approvedAssetAmount,,,,) =
                    shareClassManager.epochInvestAmounts(scId, assetId, depositEpochId);

                gte(pendingDeposit, approvedAssetAmount, "pendingDeposit < approvedAssetAmount");
                gte(pendingDeposit, pendingAssetAmount, "pendingDeposit < pendingAssetAmount");
            }
        }
    }

    /// @dev Property: The sum of pending user deposit amounts depositRequest[..] is always >= total pending deposit
    /// amount pendingDeposit[..]
    /// @dev Property: The total pending deposit amount pendingDeposit[..] is always >= the approved deposit amount
    /// epochInvestAmounts[..].approvedAssetAmount
    function property_sum_pending_user_deposit_geq_total_pending_deposit() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 depositEpochId,,,) = shareClassManager.epochId(scId, assetId);
                uint128 pendingDeposit = shareClassManager.pendingDeposit(scId, assetId);

                // get the pending and approved deposit amounts for the current epoch
                (uint128 pendingAssetAmount, uint128 approvedAssetAmount,,,,) =
                    shareClassManager.epochInvestAmounts(scId, assetId, depositEpochId);

                uint128 totalPendingUserDeposit = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];

                    (uint128 pendingUserDeposit,) =
                        shareClassManager.depositRequest(scId, assetId, CastLib.toBytes32(actor));
                    totalPendingUserDeposit += pendingUserDeposit;
                }

                // check that the pending deposit is >= the total pending user deposit
                gte(totalPendingUserDeposit, pendingDeposit, "total pending user deposits is < pending deposit");
                // check that the pending deposit is >= the approved deposit
                gte(pendingDeposit, approvedAssetAmount, "pending deposit is < approved deposit");
            }
        }
    }

    /// @dev Property: The the sum of pending user redeem amounts redeemRequest[..] is always >= total pending redeem
    /// amount pendingRedeem[..]
    /// @dev Property: The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount
    /// epochRedeemAmounts[..].approvedShareAmount
    // TODO: come back to this to check if accounting for case is correct
    function property_sum_pending_user_redeem_geq_total_pending_redeem() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 redeemEpochId,,,) = shareClassManager.epochId(scId, assetId);
                uint128 pendingRedeemCurrent = shareClassManager.pendingRedeem(scId, assetId);

                // get the pending and approved redeem amounts for the previous epoch
                (, uint128 approvedShareAmountPrevious, uint128 payoutAssetAmountPrevious,,,) =
                    shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId - 1);

                // get the pending and approved redeem amounts for the current epoch
                (, uint128 approvedShareAmountCurrent, uint128 payoutAssetAmountCurrent,,,) =
                    shareClassManager.epochRedeemAmounts(scId, assetId, redeemEpochId);

                uint128 totalPendingUserRedeem = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];

                    (uint128 pendingUserRedeemCurrent,) =
                        shareClassManager.redeemRequest(scId, assetId, CastLib.toBytes32(actor));
                    totalPendingUserRedeem += pendingUserRedeemCurrent;

                    // pendingUserRedeem hasn't changed if the claimableAssetAmountPrevious is 0, so we can use it to
                    // calculate the claimableAssetAmount from the previous epoch
                    approvedShareAmountPrevious = pendingUserRedeemCurrent.mulDiv(
                        approvedShareAmountPrevious, payoutAssetAmountPrevious
                    ).toUint128();
                    uint128 claimableAssetAmountPrevious = uint256(approvedShareAmountPrevious).mulDiv(
                        payoutAssetAmountPrevious, approvedShareAmountPrevious
                    ).toUint128();

                    // account for the edge case where user claimed redemption in previous epoch but there was no
                    // claimable amount
                    // in this case, the totalPendingUserRedeem will be greater than the pendingRedeemCurrent for this
                    // epoch
                    if (claimableAssetAmountPrevious > 0) {
                        // check that the pending redeem is >= the total pending user redeem
                        gte(
                            totalPendingUserRedeem,
                            pendingRedeemCurrent,
                            "total pending user redeems is < pending redeem"
                        );
                    }
                }

                // check that the pending redeem is >= the approved redeem
                gte(pendingRedeemCurrent, approvedShareAmountCurrent, "pending redeem is < approved redeem");
            }
        }
    }

    /// @dev Property: The epoch of a pool epochId[poolId] can increase at most by one within the same transaction
    /// (i.e. multicall/execute) independent of the number of approvals
    function property_epochId_can_increase_by_one_within_same_transaction() public {
        // precondition: there must've been a batch operation (call to execute/multicall)
        if (currentOperation == OpType.BATCH) {
            for (uint256 i = 0; i < createdPools.length; i++) {
                PoolId poolId = createdPools[i];
                uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
                // skip the first share class because it's never assigned
                for (uint32 j = 1; j < shareClassCount; j++) {
                    ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                    AssetId assetId = hubRegistry.currency(poolId);

                    uint32 depositEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].deposit - _before.ghostEpochId[scId][assetId].deposit;
                    uint32 redeemEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].redeem - _before.ghostEpochId[scId][assetId].redeem;
                    uint32 issueEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].issue - _before.ghostEpochId[scId][assetId].issue;
                    uint32 revokeEpochIdDifference =
                        _after.ghostEpochId[scId][assetId].revoke - _before.ghostEpochId[scId][assetId].revoke;

                    // check that the epochId increased by at most 1
                    lte(depositEpochIdDifference, 1, "deposit epochId increased by more than 1");
                    lte(redeemEpochIdDifference, 1, "redeem epochId increased by more than 1");
                    lte(issueEpochIdDifference, 1, "issue epochId increased by more than 1");
                    lte(revokeEpochIdDifference, 1, "revoke epochId increased by more than 1");
                }
            }
        }
    }

    /// @dev Property: account.totalDebit and account.totalCredit is always less than uint128(type(int128).max)
    function property_account_totalDebit_and_totalCredit_leq_max_int128() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);
                // loop over all account types defined in IHub::AccountType
                for (uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (uint128 totalDebit, uint128 totalCredit,,,) = accounting.accounts(poolId, accountId);
                    lte(totalDebit, uint128(type(int128).max), "totalDebit is greater than max int128");
                    lte(totalCredit, uint128(type(int128).max), "totalCredit is greater than max int128");
                }
            }
        }
    }

    /// @dev Property: Any decrease in valuation should not result in an increase in accountValue
    function property_decrease_valuation_no_increase_in_accountValue() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                if (_before.ghostHolding[poolId][scId][assetId] > _after.ghostHolding[poolId][scId][assetId]) {
                    // loop over all account types defined in IHub::AccountType
                    for (uint8 kind = 0; kind < 6; kind++) {
                        AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                        uint128 accountValueBefore = _before.ghostAccountValue[poolId][accountId];
                        uint128 accountValueAfter = _after.ghostAccountValue[poolId][accountId];
                        if (accountValueAfter > accountValueBefore) {
                            t(false, "accountValue increased");
                        }
                    }
                }
            }
        }
    }

    /// @dev Property: Value of Holdings == accountValue(Asset)
    function property_accounting_and_holdings_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);
                AccountId accountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));

                (, uint128 assets) = accounting.accountValue(poolId, accountId);
                uint128 holdingsValue = holdings.value(poolId, scId, assetId);

                // This property holds all of the system accounting together
                eq(assets, holdingsValue, "Assets and Holdings value must match");
            }
        }
    }

    /// @dev Property: Total Yield = assets - equity
    function property_total_yield() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);

                if (assets > equity) {
                    // Yield
                    (, uint128 yield) = accounting.accountValue(poolId, gainAccountId);
                    t(yield == assets - equity, "property_total_yield gain");
                } else if (assets < equity) {
                    // Loss
                    (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);
                    t(loss == assets - equity, "property_total_yield loss"); // Loss is negative
                }
            }
        }
    }

    /// @dev Property: assets = equity + gain + loss
    function property_asset_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

                // assets = accountValue(Equity) + accountValue(Gain) - accountValue(Loss)
                t(assets == equity + gain - loss, "property_asset_soundness"); // Loss is already negative
            }
        }
    }

    /// @dev Property: equity = assets - loss - gain
    function property_equity_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

                // equity = accountValue(Asset) + (ABS(accountValue(Loss)) - accountValue(Gain) // Loss comes back, gain
                // is subtracted
                t(equity == assets + loss - gain, "property_equity_soundness"); // Loss comes back, gain is subtracted,
                    // since loss is negative we need to negate it
            }
        }
    }

    /// @dev Property: gain = totalYield + loss
    function property_gain_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

                uint128 totalYield = assets - equity; // Can be positive or negative
                t(gain == (totalYield - loss), "property_gain_soundness");
            }
        }
    }

    /// @dev Property: loss = totalYield - gain
    function property_loss_soundness() public {
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // get the account ids for each account
                AccountId assetAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset));
                AccountId equityAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Equity));
                AccountId gainAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain));
                AccountId lossAccountId = holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss));

                (, uint128 assets) = accounting.accountValue(poolId, assetAccountId);
                (, uint128 equity) = accounting.accountValue(poolId, equityAccountId);
                (, uint128 gain) = accounting.accountValue(poolId, gainAccountId);
                (, uint128 loss) = accounting.accountValue(poolId, lossAccountId);

                uint128 totalYield = assets - equity; // Can be positive or negative
                t(loss == totalYield - gain, "property_loss_soundness");
            }
        }
    }

    /// @dev Property: A user cannot mutate their pending redeem amount pendingRedeem[...] if
    /// the pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem
    function property_user_cannot_mutate_pending_redeem() public {
        address[] memory _actors = _getActors();

        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = CastLib.toBytes32(_actors[k]);
                    // precondition: pending has changed
                    if (
                        _before.ghostRedeemRequest[scId][assetId][actor].pending
                            != _after.ghostRedeemRequest[scId][assetId][actor].pending
                    ) {
                        // check that the lastUpdate was >= the latest redeem approval pointer
                        gt(
                            _after.ghostRedeemRequest[scId][assetId][actor].lastUpdate,
                            _after.ghostEpochId[scId][assetId].redeem,
                            "lastUpdate is > latest redeem approval"
                        );
                    }
                }
            }
        }
    }

    /// @dev Property: After FM performs approveDeposits and revokeShares with non-zero navPerShare, the total
    /// issuance totalIssuance[..] is increased
    /// @dev WIP, this may not be possible to prove because these calls are made via execute which makes determining the
    /// before and after state difficult
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

    /// @dev Property: The sum of eligible user payoutShareAmount for an epoch is <= the number of issued
    /// epochInvestAmounts[..].pendingShareAmount
    /// @dev Property: The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset
    /// epochInvestAmounts[..].pendingAssetAmount
    /// @dev Stateless because of the calls to claimDeposit which would make story difficult to read
    // TODO: fix stack too deep error
    // TODO: no longer have a pendingShareAmount in EpochInvestAmounts
    // function property_eligible_user_deposit_amount_leq_deposit_issued_amount() public statelessTest {
    //     address[] memory _actors = _getActors();

    //     // loop over all created pools
    //     for (uint256 i = 0; i < createdPools.length; i++) {
    //         PoolId poolId = createdPools[i];
    //         uint32 shareClassCount = shareClassManager.shareClassCount(poolId);

    //         // check that the epoch has ended, if not, skip
    //         // we know an epoch has ended if the epochId changed after an operation which we cache in the
    // before/after structs
    //         if (_before.ghostEpochId[poolId] == _after.ghostEpochId[poolId]) {
    //             continue;
    //         }

    //         // loop over all share classes in the pool
    //         uint128 totalPayoutShareAmount = 0;
    //         uint128 totalPayoutAssetAmount = 0;
    //         // skip the first share class because it's never assigned
    //         for (uint32 j = 1; j < shareClassCount; j++) {
    //             ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
    //             AssetId assetId = hubRegistry.currency(poolId);

    //             (uint32 latestDepositEpochId,, uint32 latestIssuanceEpochId,) = shareClassManager.epochId(scId,
    // assetId);
    //             // sum up to the latest issuance epoch where users can claim deposits for
    //             uint128 sumDepositApprovedShares;
    //             uint128 sumDepositAssets;
    //             for (uint32 epochId; epochId <= latestIssuanceEpochId; epochId++) {
    //                 (uint128 depositSharesIssued,, uint128 depositPoolApproved,,,) =
    // shareClassManager.epochInvestAmounts(scId, assetId, latestDepositEpochId);
    //                 sumDepositApprovedShares += depositPoolApproved;
    //                 sumDepositAssets += depositSharesIssued;
    //             }

    //             // loop over all actors
    //             for (uint256 k = 0; k < _actors.length; k++) {
    //                 address actor = _actors[k];

    //                 // we claim via shareClassManager directly here because PoolRouter doesn't return the
    // payoutShareAmount
    //                 (uint128 payoutShareAmount, uint128 payoutAssetAmount,,) = shareClassManager.claimDeposit(poolId,
    // scId, CastLib.toBytes32(actor), assetId);
    //                 totalPayoutShareAmount += payoutShareAmount;
    //                 totalPayoutAssetAmount += payoutAssetAmount;
    //             }

    //             // check that the totalPayoutShareAmount is less than or equal to the depositSharesIssued
    //             lte(totalPayoutShareAmount, sumDepositAssets, "totalPayoutShareAmount is greater than
    // sumDepositAssets");
    //             // check that the totalPayoutAssetAmount is less than or equal to the depositPoolApproved
    //             lte(totalPayoutAssetAmount, sumDepositApprovedShares, "totalPayoutAssetAmount is greater than
    // sumDepositApprovedShares");

    //             uint128 differenceShares = sumDepositAssets - totalPayoutShareAmount;
    //             uint128 differenceAsset = sumDepositApprovedShares - totalPayoutAssetAmount;
    //             // check that the totalPayoutShareAmount is no more than 1 wei less than the depositSharesIssued
    //             lte(differenceShares, 1, "sumDepositAssets - totalPayoutShareAmount difference is greater than 1");
    //             // check that the totalPayoutAssetAmount is no more than 1 wei less than the depositAssetAmount
    //             lte(differenceAsset, 1, "sumDepositApprovedShares - totalPayoutAssetAmount difference is greater than
    // 1");
    //         }
    //     }
    // }

    /// @dev Property: The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset
    /// epochRedeemAmounts[..].approvedAssetAmount
    /// @dev Property: The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share
    /// epochRedeemAmounts[..].pendingAssetAmount
    /// @dev This doesn't sum over previous epochs because it can be assumed that it'll be called by the fuzzer for each
    /// current epoch
    function property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount() public statelessTest {
        address[] memory _actors = _getActors();

        // loop over all created pools
        for (uint256 i = 0; i < createdPools.length; i++) {
            PoolId poolId = createdPools[i];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            // loop over all share classes in the pool
            // skip the first share class because it's never assigned
            for (uint32 j = 1; j < shareClassCount; j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (,,, uint32 latestRevocationEpochId) = shareClassManager.epochId(scId, assetId);
                // sum up to the latest revocation epoch where users can claim redemptions for
                uint128 sumRedeemApprovedShares;
                uint128 sumRedeemAssets;
                for (uint32 epochId; epochId <= latestRevocationEpochId; epochId++) {
                    (uint128 redeemAssets, uint128 redeemApprovedShares,,,,) =
                        shareClassManager.epochRedeemAmounts(scId, assetId, epochId);
                    sumRedeemApprovedShares += redeemApprovedShares;
                    sumRedeemAssets += redeemAssets;
                }

                // sum eligible user claim payoutAssetAmount for the epoch
                uint128 totalPayoutAssetAmount = 0;
                uint128 totalPaymentShareAmount = 0;
                for (uint256 k = 0; k < _actors.length; k++) {
                    address actor = _actors[k];
                    // we claim via shareClassManager directly here because PoolRouter doesn't return the
                    // payoutAssetAmount
                    (uint128 payoutAssetAmount, uint128 paymentShareAmount,,) =
                        shareClassManager.claimRedeem(poolId, scId, CastLib.toBytes32(actor), assetId);
                    totalPayoutAssetAmount += payoutAssetAmount;
                    totalPaymentShareAmount += paymentShareAmount;
                }

                // check that the totalPayoutAssetAmount is less than or equal to the sum of redeemAssets
                lte(totalPayoutAssetAmount, sumRedeemAssets, "total payout asset amount is > redeem assets");
                // check that the totalPaymentShareAmount is less than or equal to the sum of redeemApprovedShares
                lte(
                    totalPaymentShareAmount,
                    sumRedeemApprovedShares,
                    "total payment share amount is > redeem shares revoked"
                );

                uint128 differenceAsset = sumRedeemAssets - totalPayoutAssetAmount;
                uint128 differenceShare = sumRedeemApprovedShares - totalPaymentShareAmount;
                // check that the totalPayoutAssetAmount is no more than 1 wei less than the sum of redeemAssets
                lte(differenceAsset, 1, "sumRedeemAssets - totalPayoutAssetAmount difference is greater than 1");
                // check that the totalPaymentShareAmount is no more than 1 wei less than the sum of redeemApproved
                lte(
                    differenceShare, 1, "sumRedeemApprovedShares - totalPaymentShareAmount difference is greater than 1"
                );
            }
        }
    }

    /// @dev Property: The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to
    /// the balance of the escrow for said pool-shareClass for the respective token
    // TODO: verify if this should be applied to the vaults side instead
    // function property_holdings_balance_equals_escrow_balance() public statelessTest {
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
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow,
    // assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());

    //             eq(holdingAssetAmount, pendingShareClassEscrowBalance + shareClassEscrowBalance, "holding != escrow
    // balance");
    //         }
    //     }
    // }

    /// @dev Property: The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the
    /// associated token in the escrow
    // TODO: confirm if this is correct because it seems like AssetRegistry would never be receiving tokens in the first
    // place
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
    //             uint256 pendingShareClassEscrowBalance = assetRegistry.balanceOf(pendingShareClassEscrow,
    // assetId.raw());
    //             uint256 shareClassEscrowBalance = assetRegistry.balanceOf(shareClassEscrow, assetId.raw());

    //             lte(assetRegistryBalance, pendingShareClassEscrowBalance + shareClassEscrowBalance, "assetRegistry
    // balance > escrow balance");
    //         }
    //     }
    // }
}

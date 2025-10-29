| # | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1 | vault_maxDeposit | user can always maxDeposit if they have > 0 assets and are approved | ✅ |
| 2 | vault_maxDeposit | user can always deposit an amount between 1 and maxDeposit if they have > 0 assets and are approved | ✅ |
| 3 | vault_maxDeposit | maxDeposit should decrease by the amount deposited | ✅ |
| 4 | vault_maxDeposit | depositing maxDeposit blocks the user from depositing more | ✅ |
| 5 | vault_maxDeposit | depositing maxDeposit does not increase the pendingDeposit | ✅ |
| 6 | vault_maxDeposit | depositing maxDeposit doesn't mint more than maxMint shares | ✅ |
| 7 | vault_maxDeposit | For async vaults, validates globalEscrow share transfers | ✅ |
| 8 | vault_maxDeposit | For sync vaults, validates PoolEscrow state changes | ✅ |
| 9 | vault_maxMint | user can always maxMint if they have > 0 assets and are approved | ✅ |
| 10 | vault_maxMint | user can always mint an amount between 1 and maxMint if they have > 0 assets and are approved | ✅ |
| 11 | vault_maxMint | maxMint should be 0 after using maxMint as mintAmount | ✅ |
| 12 | vault_maxMint | minting maxMint should not mint more than maxDeposit shares | ✅ |
| 13 | vault_maxWithdraw | user can always maxWithdraw if they have > 0 shares and are approved | ✅ |
| 14 | vault_maxWithdraw | user can always withdraw an amount between 1 and maxWithdraw if they have > 0 shares and are approved | ❌ |
| 15 | vault_maxWithdraw | maxWithdraw should decrease by the amount withdrawn | ✅ |
| 16 | vault_maxRedeem | user can always maxRedeem if they have > 0 shares and are approved | ✅ |
| 17 | vault_maxRedeem | user can always redeem an amount between 1 and maxRedeem if they have > 0 shares and are approved | ✅ |
| 18 | vault_maxRedeem | redeeming maxRedeem does not increase the pendingRedeem | ✅ |
| 19 | erc7540_3 | 7540-3 convertToAssets(totalSupply) == totalAssets unless price is 0.0 | ✅ |
| 20 | erc7540_4 | 7540-4 convertToShares(totalAssets) == totalSupply unless price is 0.0 | ✅ |
| 21 | erc7540_5 | 7540-5 max* never reverts | ✅ |
| 22 | erc7540_6_deposit | 7540-6 claiming more than max always reverts | ✅ |
| 23 | erc7540_7 | 7540-7 requestRedeem reverts if the share balance is less than amount | ✅ |
| 24 | erc7540_8 | 7540-8 preview* always reverts | ✅ |
| 25 | erc7540_9_deposit | 7540-9 if max[method] > 0, then [method] (max) should not revert | ✅ |
| 26 | property_sum_of_shares_received | Sum of share tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares | ✅ |
| 27 | property_sum_of_assets_received | the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest | ✅ |
| 28 | property_sum_of_pending_redeem_request | the payout of the escrow is always <= sum of redemptions paid out | ✅ |
| 29 | property_system_addresses_never_receive_share_tokens | System addresses should never receive share tokens | ✅ |
| 30 | property_sum_of_received_leq_fulfilled_inductive | Claimable cancel redeem request delta equals escrow balance delta | ✅ |
| 31 | property_last_update_on_request_deposit | after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate | ✅ |
| 32 | property_last_update_on_request_redeem | After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate equals nowRedeemEpoch | ✅ |
| 33 | property_share_balance_delta | user share balance correctly changes by the same amount of shares added to the escrow | ✅ |
| 34 | property_asset_balance_delta | user asset balance correctly changes by the same amount of assets added to the escrow | ✅ |
| 35 | property_deposit_share_balance_delta | user share balance correctly changes by the same amount of shares transferred from escrow on deposit/mint | ✅ |
| 36 | property_redeem_asset_balance_delta | user asset balance correctly changes by the same amount of assets transferred from pool escrow on redeem/withdraw | ✅ |
| 37 | property_sum_of_balances | Sum of balances equals total supply | ✅ |
| 38 | property_price_on_fulfillment | The price at which a user deposit is made is bounded by the price when the request was fulfilled | ✅ |
| 39 | property_price_on_redeem | The price at which a user redemption is made is bounded by the price when the request was | ✅ |
| 40 | property_escrow_balance | The balance of currencies in Escrow is the sum of deposit requests -minus sum of claimed | ✅ |
| 41 | property_sum_of_possible_account_balances_leq_escrow | The sum of account balances is always <= the balance of the escrow | ✅ |
| 42 | property_sum_of_possible_account_balances_leq_escrow | The sum of max claimable shares is always <= the share balance of the escrow | ✅ |
| 43 | property_totalAssets_insolvency_only_increases | the totalAssets of a vault is always <= actual assets in the vault | ✅ |
| 44 | property_totalAssets_insolvency_only_increases | difference between totalAssets and actualAssets only increases | ✅ |
| 45 | property_soundness_processed_deposits | requested deposits must be >= the deposits fulfilled | ✅ |
| 46 | property_soundness_processed_redemptions | requested redemptions must be >= the redemptions fulfilled | ✅ |
| 47 | property_cancelled_soundness | requested deposits must be >= the fulfilled cancelled deposits | ✅ |
| 48 | property_cancelled_and_processed_deposits_soundness | requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits | ✅ |
| 49 | property_cancelled_and_processed_redemptions_soundness | requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions | ✅ |
| 50 | property_solvency_deposit_requests | total deposits must be >= the approved deposits | ✅ |
| 51 | property_solvency_redemption_requests | total redemptions must be >= the approved redemptions | ✅ |
| 52 | property_actor_pending_and_queued_deposits | actor requested deposits - cancelled deposits - processed deposits actor pending deposits + | ✅ |
| 53 | property_actor_pending_and_queued_redemptions | actor requested redemptions - cancelled redemptions - processed redemptions = actor pending | ✅ |
| 54 | property_total_pending_and_approved | escrow total must be >= reserved | ✅ |
| 55 | property_total_pending_and_approved | The price per share used in the entire system is ALWAYS provided by the admin | ✅ |
| 56 | property_total_pending_and_approved | The total pending asset amount pendingDeposit[..] is always >= the approved asset | ✅ |
| 57 | property_sum_pending_user_deposit_geq_total_pending_deposit | The sum of pending user deposit amounts depositRequest[..] is always >= total pending deposit | ✅ |
| 58 | property_sum_pending_user_deposit_geq_total_pending_deposit | The total pending deposit amount pendingDeposit[..] is always >= the approved deposit amount | ✅ |
| 59 | property_sum_pending_user_redeem_geq_total_pending_redeem | The sum of pending user redeem amounts redeemRequest[..] is always >= total pending redeem amount | ✅ |
| 60 | property_sum_pending_user_redeem_geq_total_pending_redeem | The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount | ✅ |
| 61 | property_epochId_can_increase_by_one_within_same_transaction | The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. | ✅ |
| 62 | property_decrease_valuation_no_increase_in_accountValue | account.totalDebit and account.totalCredit is always less than uint128(type(int128).max) | ✅ |
| 63 | property_decrease_valuation_no_increase_in_accountValue | Any decrease in valuation should not result in an increase in accountValue | ✅ |
| 64 | property_accounting_and_holdings_soundness | Value of Holdings == accountValue(Asset) | ✅ |
| 65 | property_user_cannot_mutate_pending_redeem | A user cannot mutate their pending redeem amount pendingRedeem[...] if the | ✅ |
| 66 | property_total_issuance_soundness | The amount of holdings of an asset for a pool-shareClass pair in Holdings MUST always be equal to | ✅ |
| 67 | property_total_issuance_soundness | The total issuance of a share class is <= the sum of issued shares and burned shares | ✅ |
| 68 | property_additions_dont_cause_ppfs_loss | operations which increase deposits/shares don't decrease PPS | ✅ |
| 69 | property_removals_dont_cause_ppfs_loss | operations which remove deposits/shares don't decrease PPS | ✅ |
| 70 | property_additions_use_correct_price | If user deposits assets, they must always receive at least the pricePerShare | ✅ |
| 71 | property_removals_use_correct_price | If user redeems shares, they must always pay at least the pricePerShare | ✅ |
| 72 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the | ✅ |
| 73 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user payoutShareAmount for an epoch is <= the number of issued | ✅ |
| 74 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset | ✅ |
| 75 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | The sum of eligible user claim payout asset amounts for an epoch is <= the asset amount of | ✅ |
| 76 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | The sum of eligible user claim payment share amounts for an epoch is <= the approved amount of | ✅ |
| 77 | property_shareQueueFlipLogic | Issue/Revoke Logic Correctness | ✅ |
| 78 | property_deltaCheck | Issue/Revoke Logic Correctness | ✅ |
| 79 | property_shareQueueFlipBoundaries | flips between positive and negative net positions are correctly detected | ✅ |
| 80 | property_shareQueueCommutativity | net position equals total issued minus total revoked (mathematical invariant) | ✅ |
| 81 | property_shareQueueSubmission | verifies queue submission logic and reset behavior | ✅ |
| 82 | property_shareQueueAssetCounter | Verifies that the asset counter accurately reflects non-empty asset queues | ✅ |
| 83 | property_availableGtQueued | BalanceSheet must always have sufficient balance for queued assets | ❌ |
| 84 | property_authorizationBypass | authorization checks can't be bypassed | ❌ |
| 85 | property_authorizationLevel | successful authorized calls must be made by authorized accounts | ✅ |
| 86 | property_authorizationChange | authorization changes are correctly tracked | ✅ |
| 87 | property_shareTokenCountedInSupply | share token should always be included if it's been supplied | ✅ |
| 88 | property_assetShareProportionalityDeposits | Asset-Share Proportionality on Deposits | ✅ |
| 89 | property_assetShareProportionalityWithdrawals | Asset-Share Proportionality on Withdrawals | ✅ |
| 90 | _hasAsyncVaultForPoolShareClass | Total Yield = assets - equity | ✅ |
| 91 | _hasAsyncVaultForPoolShareClass | assets = equity + gain + loss | ✅ |
| 92 | _hasAsyncVaultForPoolShareClass | equity = assets - loss - gain | ✅ |
| 93 | _hasAsyncVaultForPoolShareClass | gain = totalYield + loss | ✅ |
| 94 | _hasAsyncVaultForPoolShareClass | loss = totalYield - gain | ✅ |
| 95 | hub_issueShares | After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance | ✅ |
| 96 | hub_revokeShares | After FM performs approveRedeems and revokeShares with non-zero navPerShare, the total issuance | ✅ |
| 97 | balanceSheet_noteDeposit | PoolEscrow.total increases by exactly the amount deposited | ✅ |
| 98 | balanceSheet_noteDeposit | PoolEscrow.reserved does not change during noteDeposit | ✅ |
| 99 | balanceSheet_withdraw | Withdrawals should not fail when there's sufficient balance | ✅ |
| 100 | doomsday_mint | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - | ✅ |
| 101 | doomsday_mint | user should always be able to deposit less than maxMint | ✅ |
| 102 | doomsday_mint | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - | ✅ |
| 103 | doomsday_mint | user should always be able to mint less than maxMint | ✅ |
| 104 | doomsday_redeem | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - | ✅ |
| 105 | doomsday_redeem | user should always be able to redeem less than maxWithdraw | ✅ |
| 106 | doomsday_withdraw | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - | ✅ |
| 107 | doomsday_withdraw | user should always be able to withdraw less than maxWithdraw | ✅ |
| 108 | doomsday_pricePerShare_never_changes_after_user_operation | pricePerShare never changes after a user operation | ✅ |
| 109 | doomsday_impliedPricePerShare_never_changes_after_user_operation | implied pricePerShare (totalAssets / totalSupply) never changes after a user operation | ✅ |
| 110 | doomsday_accountValue | accounting.accountValue should never revert | ✅ |
| 111 | doomsday_zeroPrice_noPanics | System handles all operations gracefully at zero price | ❌ |
| 112 | hub_notifyDeposit | After successfully calling claimDeposit for an investor (via notifyDeposit), their | ✅ |
| 113 | hub_notifyDeposit | PoolEscrow.total increases by exactly totalPaymentAssetAmount | ✅ |
| 114 | hub_notifyDeposit | PoolEscrow.reserved does not change during deposit processing | ✅ |
| 115 | hub_notifyRedeem | After successfully claimRedeem for an investor (via notifyRedeem), their | ✅ |
| 116 | token_transfer | must revert if sending to or from a frozen user | ✅ |
| 117 | token_transfer | must revert if sending to a non-member who is not endorsed | ✅ |
| 118 | token_transferFrom | must revert if sending to or from a frozen user | ✅ |
| 119 | token_transferFrom | must revert if sending to a non-member who is not endorsed | ✅ |
| 120 | vault_requestDeposit | _updateDepositRequest should never revert due to underflow | ✅ |
| 121 | vault_requestRedeem | sender or recipient can't be frozen for requested redemption | ✅ |
| 122 | vault_cancelDepositRequest | after successfully calling cancelDepositRequest for an investor, their | ✅ |
| 123 | vault_cancelDepositRequest | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending | ✅ |
| 124 | vault_cancelDepositRequest | cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in | ✅ |
| 125 | vault_cancelRedeemRequest | After successfully calling cancelRedeemRequest for an investor, their | ✅ |
| 126 | vault_cancelRedeemRequest | cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in | ✅ |
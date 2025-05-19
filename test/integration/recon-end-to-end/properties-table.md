| # | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1 | hub_depositRequest | after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch | |
| 2 | hub_depositRequest | _updateDepositRequest should never revert due to underflow | |
| 3 | hub_depositRequest | The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..] | |
| 4 | vault_requestDeposit_clamped | After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate equals nowRedeemEpoch | |
| 5 | vault_requestRedeem_clamped | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch | |
| 6 | vault_requestRedeem_clamped | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero | |
| 7 | vault_requestRedeem_clamped | cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert) | |
| 8 | vault_requestRedeem_clamped | _updateDepositRequest should never revert due to underflow | |
| 9 | vault_requestRedeem_clamped | The total pending deposit amount pendingDeposit[..] is always >= the sum of pending user deposit amounts depositRequest[..] | |
| 10 | vault_cancelDepositRequest | After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current nowRedeemEpoch | |
| 11 | vault_cancelDepositRequest | After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero | |
| 12 | vault_cancelDepositRequest | cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert) | |
| 13 | hub_createPool_clamped | After successfully calling claimDeposit for an investor (via notifyDeposit), their depositRequest[..].lastUpdate equals the nowDepositEpoch for the redeem | |
| 14 | hub_notifyDeposit | After successfully claimRedeem for an investor (via notifyRedeem), their depositRequest[..].lastUpdate equals the nowRedeemEpoch for the redemption | |
| 15 | doomsday_deposit | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | |
| 16 | doomsday_deposit | user should always be able to mint less than maxMint | |
| 17 | doomsday_mint | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | |
| 18 | doomsday_mint | user should always be able to redeem less than maxWithdraw | |
| 19 | doomsday_redeem | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | |
| 20 | doomsday_redeem | user should always be able to withdraw less than maxWithdraw | |
| 21 | property_sentinel_token_balance | Sum of share tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares | |
| 22 | property_sum_of_shares_received | the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest | |
| 23 | property_sum_of_assets_received | the sum of pendingRedeemRequest == payout of the escrow | |
| 24 | property_sum_of_pending_redeem_request | The sum of tranche tokens minted/transferred is equal to the total supply of tranche tokens | |
| 25 | property_sum_of_minted_equals_total_supply | System addresses should never receive share tokens | |
| 26 | property_system_addresses_never_receive_share_tokens | Sum of assets received on claimCancelDepositRequest <= sum of fulfillCancelDepositRequest.assets | |
| 27 | property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive | Sum of share class tokens received on claimCancelRedeemRequest <= sum of fulfillCancelRedeemRequest.shares | |
| 28 | property_sum_of_received_leq_fulfilled_inductive | Sum of balances equals total supply | |
| 29 | property_sum_of_balances | The price at which a user deposit is made is bounded by the price when the request was fulfilled | |
| 30 | property_price_on_fulfillment | The price at which a user redemption is made is bounded by the price when the request was fulfilled | |
| 31 | property_price_on_redeem | The balance of currencies in Escrow is the sum of deposit requests -minus sum of claimed redemptions + transfers in -minus transfers out | |
| 32 | property_escrow_balance | The balance of share class tokens in Escrow is the sum of all fulfilled deposits - sum of all claimed deposits + sum of all redeem requests - sum of claimed redeem requests | |
| 33 | property_escrow_share_balance | The sum of account balances is always <= the balance of the escrow | |
| 34 | property_sum_of_account_balances_leq_escrow | The sum of max claimable shares is always <= the share balance of the escrow | |
| 35 | property_sum_of_possible_account_balances_leq_escrow | the totalAssets of a vault is always <= actual assets in the vault | |
| 36 | property_totalAssets_solvency | difference between totalAssets and actualAssets only increases | |
| 37 | property_totalAssets_insolvency_only_increases | requested deposits must be >= the deposits fulfilled | |
| 38 | property_soundness_processed_deposits | requested redemptions must be >= the redemptions fulfilled | |
| 39 | property_soundness_processed_redemptions | requested deposits must be >= the fulfilled cancelled deposits | |
| 40 | property_cancelled_soundness | requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits | |
| 41 | property_cancelled_and_processed_deposits_soundness | requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions | |
| 42 | property_cancelled_and_processed_redemptions_soundness | total deposits must be >= the approved deposits | |
| 43 | property_solvency_deposit_requests | total redemptions must be >= the approved redemptions | |
| 44 | property_solvency_redemption_requests | actor requested deposits - cancelled deposits - processed deposits actor pending deposits + queued deposits | |
| 45 | property_actor_pending_and_queued_deposits | actor requested redemptions - cancelled redemptions - processed redemptions actor pending redemptions + queued redemptions | |
| 46 | property_actor_pending_and_queued_redemptions | escrow reserved must be >= holding | |
| 47 | property_escrow_solvency | The price per share used in the entire system is ALWAYS provided by the admin | |
| 48 | property_price_per_share_overall | The total pending asset amount pendingDeposit[..] is always >= the approved asset epochInvestAmounts[..].approvedAssetAmount | |
| 49 | property_total_pending_and_approved | The total pending redeem amount pendingRedeem[..] is always >= the sum of pending user redeem amounts redeemRequest[..] | |
| 50 | property_total_pending_and_approved | The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount epochRedeemAmounts[..].approvedShareAmount | |
| 51 | property_total_pending_redeem_geq_sum_pending_user_redeem | The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. multicall/execute) independent of the number of approvals | |
| 52 | property_epochId_can_increase_by_one_within_same_transaction | account.totalDebit and account.totalCredit is always less than uint128(type(int128).max) | |
| 53 | property_account_totalDebit_and_totalCredit_leq_max_int128 | Any decrease in valuation should not result in an increase in accountValue | |
| 54 | property_decrease_valuation_no_increase_in_accountValue | Value of Holdings == accountValue(Asset) | |
| 55 | property_accounting_and_holdings_soundness | Total Yield = assets - equity | |
| 56 | property_total_yield | assets = equity + gain + loss | |
| 57 | property_asset_soundness | equity = assets - loss - gain | |
| 58 | property_equity_soundness | gain = totalYield + loss | |
| 59 | property_gain_soundness | loss = totalYield - gain | |
| 60 | property_loss_soundness | A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem | |
| 61 | property_user_cannot_mutate_pending_redeem | After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance totalIssuance[..] is increased | |
| 62 | property_total_issuance_decreased_after_approve_redeems_and_revoke_shares | The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to the balance of the escrow for said pool-shareClass for the respective token | |
| 63 | property_holdings_balance_equals_escrow_balance | The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the associated token in the escrow | |
| 64 | property_holdings_balance_equals_escrow_balance | The sum of eligible user payoutShareAmount for an epoch is <= the number of issued epochInvestAmounts[..].pendingShareAmount | |
| 65 | property_holdings_balance_equals_escrow_balance | The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset epochInvestAmounts[..].pendingAssetAmount | |
| 66 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset epochRedeemAmounts[..].approvedAssetAmount | |
| 67 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share epochRedeemAmounts[..].pendingAssetAmount | |
| 68 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | pricePerShare never changes after a user operation | |
| 69 | doomsday_pricePerShare_never_changes_after_user_operation | implied pricePerShare (totalAssets / totalSupply) never changes after a user operation | |
| 70 | doomsday_impliedPricePerShare_never_changes_after_user_operation | accounting.accountValue should never revert | |
| 71 | asyncVault_9_redeem | user can always maxDeposit if they have > 0 assets and are approved | |
| 72 | asyncVault_9_redeem | user can always deposit an amount between 1 and maxDeposit have > 0 assets and are approved | |
| 73 | asyncVault_9_redeem | maxDeposit should decrease by the amount deposited | |
| 74 | asyncVault_9_redeem | depositing maxDeposit leaves a user with 0 orders | |
| 75 | asyncVault_9_redeem | depositing maxDeposit doesn't mint more than maxMint shares | |
| 76 | asyncVault_maxDeposit | user can always maxMint if they have > 0 assets and are approved | |
| 77 | asyncVault_maxDeposit | user can always mint an amount between 1 and maxMint have > 0 assets and are approved | |
| 78 | asyncVault_maxDeposit | maxMint should be 0 after using maxMint as mintAmount | |
| 79 | asyncVault_maxDeposit | minting maxMint should not mint more than maxDeposit shares | |
| 80 | asyncVault_maxWithdraw | redeeming maxRedeem leaves user with 0 pending redeem requests | |

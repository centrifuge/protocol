| # | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1 | asyncVault_maxDeposit | user can always maxDeposit if they have > 0 assets and are approved | ✅ |
| 2 | asyncVault_maxDeposit | user can always deposit an amount between 1 and maxDeposit, have > 0 assets and are approved | ✅ |
| 3 | asyncVault_maxDeposit | maxDeposit should decrease by the amount deposited | ❌ |
| 4 | asyncVault_maxDeposit | depositing maxDeposit leaves a user with 0 orders | ✅ |
| 5 | asyncVault_maxDeposit | depositing maxDeposit doesn't mint more than maxMint shares | ✅ |
| 6 | asyncVault_maxMint | user can always maxMint if they have > 0 assets and are approved | ✅ |
| 7 | asyncVault_maxMint | user can always mint an amount between 1 and maxMint have > 0 assets and are approved | ✅ |
| 8 | asyncVault_maxMint | maxMint should be 0 after using maxMint as mintAmount | ✅ |
| 9 | asyncVault_maxDeposit | minting maxMint should not mint more than maxDeposit shares | ✅ |
| 10 | asyncVault_maxRedeem | redeeming maxRedeem leaves user with 0 pending redeem requests | ✅ |
| 11 | asyncVault_maxRedeem | redeeming decreases maxRedeem by the redeemed amount  | ❌ |
| 12 | property_sentinel_token_balance | Sum of share tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares | ✅ |
| 13 | property_sum_of_shares_received | the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest | ❌ |
| 14 | property_sum_of_assets_received | the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest | ✅ |
| 15 | property_sum_of_pending_redeem_request | the payout of the escrow is always <= sum of redemptions paid out | ❌ |
| 16 | property_sum_of_minted_equals_total_supply | The sum of tranche tokens minted/transferred is equal to the total supply of tranche tokens | ❌ |
| 17 | property_system_addresses_never_receive_share_tokens | System addresses should never receive share tokens | ✅ |
| 18 | property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive | Sum of assets received on claimCancelDepositRequest <= sum of fulfillCancelDepositRequest.assets | ✅ |
| 19 | property_sum_of_received_leq_fulfilled_inductive | Sum of share class tokens received on claimCancelRedeemRequest <= sum of fulfillCancelRedeemRequest.shares | ❌ |
| 20 | property_sum_of_balances | Sum of balances equals total supply | ✅ |
| 21 | property_price_on_fulfillment | The price at which a user deposit is made is bounded by the price when the request was fulfilled | ✅ |
| 22 | property_price_on_redeem | The price at which a user redemption is made is bounded by the price when the request was fulfilled | ✅ |
| 23 | property_escrow_balance | The balance of currencies in Escrow is the sum of deposit requests -minus sum of claimed redemptions + transfers in -minus transfers out | ❌ |
| 24 | property_escrow_share_balance | The balance of share class tokens in Escrow is the sum of all fulfilled deposits - sum of all claimed deposits + sum of all redeem requests - sum of claimed redeem requests | ❌ |
| 25 | property_sum_of_possible_account_balances_leq_escrow | The sum of max claimable shares is always <= the share balance of the escrow | ✅ |
| 26 | property_totalAssets_solvency | the totalAssets of a vault is always <= actual assets in the vault | ❌ |
| 27 | property_totalAssets_insolvency_only_increases | difference between totalAssets and actualAssets only increases | ✅ |
| 28 | property_soundness_processed_deposits | requested deposits must be >= the deposits fulfilled | ✅ |
| 29 | property_soundness_processed_redemptions | requested redemptions must be >= the redemptions fulfilled | ✅ |
| 30 | property_cancelled_soundness | requested deposits must be >= the fulfilled cancelled deposits | ✅ |
| 31 | property_cancelled_and_processed_deposits_soundness | requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits | ✅ |
| 32 | property_cancelled_and_processed_redemptions_soundness | requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions | ✅ |
| 33 | property_solvency_deposit_requests | total deposits must be >= the approved deposits | ✅ |
| 34 | property_solvency_redemption_requests | total redemptions must be >= the approved redemptions | ✅ |
| 35 | property_actor_pending_and_queued_deposits | actor requested deposits - cancelled deposits - processed deposits = actor pending deposits + queued deposits | ✅ |
| 36 | property_actor_pending_and_queued_redemptions | actor requested redemptions - cancelled redemptions - processed redemptions = actor pending redemptions + queued redemptions | ✅ |
| 37 | property_total_pending_and_approved | The total pending asset amount pendingDeposit[..] is always >= the approved asset epochInvestAmounts[..].approvedAssetAmount | ✅ |
| 38 | property_sum_pending_user_deposit_geq_total_pending_deposit | The sum of pending user deposit amounts depositRequest[..] is always >= total pending deposit amount pendingDeposit[..] | ✅ |
| 39 | property_sum_pending_user_redeem_geq_total_pending_redeem | The sum of pending user redeem amounts redeemRequest[..] is always >= total pending redeem amount pendingRedeem[..] | ✅ |
| 40 | property_epochId_can_increase_by_one_within_same_transaction | The epoch of a pool epochId[poolId] can increase at most by one within the same transaction | ✅ |
| 41 | property_decrease_valuation_no_increase_in_accountValue | Any decrease in valuation should not result in an increase in accountValue | ✅ |
| 42 | property_accounting_and_holdings_soundness | Value of Holdings == accountValue(Asset) | ✅ |
| 43 | property_total_yield | Total Yield = assets - equity | ✅ |
| 44 | property_asset_soundness | assets = equity + gain + loss | ✅ |
| 45 | property_equity_soundness | equity = assets - loss - gain | ❌ |
| 46 | property_gain_soundness | gain = totalYield + loss | ✅ |
| 47 | property_loss_soundness | loss = totalYield - gain | ❌ |
| 48 | property_user_cannot_mutate_pending_redeem | A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem | ✅ |
| 49 | property_holdings_balance_equals_escrow_balance | The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to the balance of the escrow for said pool-shareClass for the respective token | ✅ |
| 50 | property_total_issuance_soundness | The total issuance of a share class is <= the sum of issued shares and burned shares | ❌ |
| 51 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user payoutShareAmount for an epoch is <= the number of issued epochInvestAmounts[..].pendingShareAmount | ✅ |
| 52 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | The sum of eligible user claim payout asset amounts for an epoch is <= the asset amount of revoked share class tokens epochRedeemAmounts[..].payoutAssetAmount | ✅ |
| 53 | doomsday_pricePerShare_never_changes_after_user_operation | pricePerShare never changes after a user operation | ✅ |
| 54 | doomsday_impliedPricePerShare_never_changes_after_user_operation | implied pricePerShare (totalAssets / totalSupply) never changes after a user operation | ✅ |
| 55 | doomsday_accountValue | accounting.accountValue should never revert | ✅ |
| 56 | doomsday_deposit | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | ✅ |
| 57 | doomsday_mint | user should always be able to mint less than maxMint | ✅ |
| 58 | doomsday_redeem | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | ✅ |
| 59 | doomsday_withdraw | user should always be able to withdraw less than maxWithdraw | ✅ |
| 60 | hub_notifyDeposit | After successfully calling claimDeposit for an investor (via notifyDeposit), their depositRequest[..].lastUpdate equals the nowDepositEpoch for the redeem | ❌ |
| 61 | hub_notifyRedeem | After successfully claimRedeem for an investor (via notifyRedeem), their depositRequest[..].lastUpdate equals the nowRedeemEpoch for the redemption | ✅ |
| 62 | token_approve | must revert if sending to or from a frozen user | ✅ |
| 63 | token_approve | must revert if sending to a non-member who is not endorsed | ✅ |
| 64 | _getTokenAndBalanceForVault | after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch | ✅ |
| 65 | _getTokenAndBalanceForVault | _updateDepositRequest should never revert due to underflow | ✅ |
| 66 | vault_requestDeposit | After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate equals nowRedeemEpoch | ✅ |
| 67 | vault_requestRedeem | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch | ✅ |
| 68 | vault_requestRedeem | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero | ✅ |
| 69 | vault_requestRedeem | cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert) | ✅ |
| 70 | vault_cancelDepositRequest | After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current nowRedeemEpoch | ✅ |
| 71 | vault_cancelDepositRequest | After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero | ✅ |
| 72 | vault_cancelDepositRequest | cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert) | ✅ |
| # | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1 | asyncVault_9_redeem | user can always maxDeposit if they have > 0 assets and are approved | |
| 2 | asyncVault_9_redeem | user can always deposit an amount between 1 and maxDeposit, have > 0 assets and are approved | |
| 3 | asyncVault_9_redeem | maxDeposit should decrease by the amount deposited | |
| 4 | asyncVault_9_redeem | depositing maxDeposit leaves a user with 0 orders | |
| 5 | asyncVault_9_redeem | depositing maxDeposit doesn't mint more than maxMint shares | |
| 6 | asyncVault_maxDeposit | user can always maxMint if they have > 0 assets and are approved | |
| 7 | asyncVault_maxDeposit | user can always mint an amount between 1 and maxMint have > 0 assets and are approved | |
| 8 | asyncVault_maxDeposit | maxMint should be 0 after using maxMint as mintAmount | |
| 9 | asyncVault_maxDeposit | minting maxMint should not mint more than maxDeposit shares | |
| 10 | asyncVault_maxWithdraw | redeeming maxRedeem leaves user with 0 pending redeem requests | |
| 11 | property_sentinel_token_balance | Sum of share tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares | |
| 12 | property_sum_of_shares_received | the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest | |
| 13 | property_sum_of_assets_received | the payout of the escrow is always <= sum of redemptions paid out | |
| 14 | property_sum_of_pending_redeem_request | The sum of tranche tokens minted/transferred is equal to the total supply of tranche tokens | |
| 15 | property_sum_of_minted_equals_total_supply | System addresses should never receive share tokens | |
| 16 | property_system_addresses_never_receive_share_tokens | Sum of assets received on claimCancelDepositRequest <= sum of fulfillCancelDepositRequest.assets | |
| 17 | property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive | Sum of share class tokens received on claimCancelRedeemRequest <= sum of fulfillCancelRedeemRequest.shares | |
| 18 | property_sum_of_received_leq_fulfilled_inductive | Sum of balances equals total supply | |
| 19 | property_sum_of_balances | The price at which a user deposit is made is bounded by the price when the request was fulfilled | |
| 20 | property_price_on_fulfillment | The price at which a user redemption is made is bounded by the price when the request was fulfilled | |
| 21 | property_price_on_redeem | The balance of currencies in Escrow is the sum of deposit requests -minus sum of claimed redemptions + transfers in -minus transfers out | |
| 22 | property_escrow_balance | The balance of share class tokens in Escrow is the sum of all fulfilled deposits - sum of all claimed deposits + sum of all redeem requests - sum of claimed redeem requests | |
| 23 | property_escrow_share_balance | The sum of account balances is always <= the balance of the escrow | |
| 24 | property_escrow_share_balance | The sum of max claimable shares is always <= the share balance of the escrow | |
| 25 | property_sum_of_possible_account_balances_leq_escrow | the totalAssets of a vault is always <= actual assets in the vault | |
| 26 | property_totalAssets_solvency | difference between totalAssets and actualAssets only increases | |
| 27 | property_totalAssets_insolvency_only_increases | requested deposits must be >= the deposits fulfilled | |
| 28 | property_soundness_processed_deposits | requested redemptions must be >= the redemptions fulfilled | |
| 29 | property_soundness_processed_redemptions | requested deposits must be >= the fulfilled cancelled deposits | |
| 30 | property_cancelled_soundness | requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits | |
| 31 | property_cancelled_and_processed_deposits_soundness | requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions | |
| 32 | property_cancelled_and_processed_redemptions_soundness | total deposits must be >= the approved deposits | |
| 33 | property_solvency_deposit_requests | total redemptions must be >= the approved redemptions | |
| 34 | property_solvency_redemption_requests | actor requested deposits - cancelled deposits - processed deposits actor pending deposits + queued deposits | |
| 35 | property_actor_pending_and_queued_deposits | actor requested redemptions - cancelled redemptions - processed redemptions = actor pending redemptions + queued redemptions | |
| 36 | property_actor_pending_and_queued_redemptions | escrow total must be >= reserved | |
| 37 | property_actor_pending_and_queued_redemptions | The price per share used in the entire system is ALWAYS provided by the admin | |
| 38 | property_actor_pending_and_queued_redemptions | The total pending asset amount pendingDeposit[..] is always >= the approved asset epochInvestAmounts[..].approvedAssetAmount | |
| 39 | property_total_pending_and_approved | The sum of pending user deposit amounts depositRequest[..] is always >= total pending deposit amount pendingDeposit[..] | |
| 40 | property_total_pending_and_approved | The total pending deposit amount pendingDeposit[..] is always >= the approved deposit amount epochInvestAmounts[..].approvedAssetAmount | |
| 41 | property_sum_pending_user_deposit_geq_total_pending_deposit | The sum of pending user redeem amounts redeemRequest[..] is always >= total pending redeem amount pendingRedeem[..] | |
| 42 | property_sum_pending_user_deposit_geq_total_pending_deposit | The total pending redeem amount pendingRedeem[..] is always >= the approved redeem amount epochRedeemAmounts[..].approvedShareAmount | |
| 43 | property_sum_pending_user_redeem_geq_total_pending_redeem | The epoch of a pool epochId[poolId] can increase at most by one within the same transaction (i.e. multicall/execute) independent of the number of approvals | |
| 44 | property_epochId_can_increase_by_one_within_same_transaction | account.totalDebit and account.totalCredit is always less than uint128(type(int128).max) | |
| 45 | property_account_totalDebit_and_totalCredit_leq_max_int128 | Any decrease in valuation should not result in an increase in accountValue | |
| 46 | property_decrease_valuation_no_increase_in_accountValue | Value of Holdings == accountValue(Asset) | |
| 47 | property_accounting_and_holdings_soundness | Total Yield = assets - equity | |
| 48 | property_total_yield | assets = equity + gain + loss | |
| 49 | property_asset_soundness | equity = assets - loss - gain | |
| 50 | property_equity_soundness | gain = totalYield + loss | |
| 51 | property_gain_soundness | loss = totalYield - gain | |
| 52 | property_loss_soundness | A user cannot mutate their pending redeem amount pendingRedeem[...] if the pendingRedeem[..].lastUpdate is <= the latest redeem approval epochId[..].redeem | |
| 53 | property_user_cannot_mutate_pending_redeem | The amount of holdings of an asset for a pool-shareClas pair in Holdings MUST always be equal to the balance of the escrow for said pool-shareClass for the respective token | |
| 54 | property_holdings_balance_equals_escrow_balance | The total issuance of a share class is <= the sum of issued shares and burned shares | |
| 55 | property_total_issuance_soundness | The amount of tokens existing in the AssetRegistry MUST always be <= the balance of the associated token in the escrow | |
| 56 | property_total_issuance_soundness | The sum of eligible user payoutShareAmount for an epoch is <= the number of issued epochInvestAmounts[..].pendingShareAmount | |
| 57 | property_total_issuance_soundness | The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset epochInvestAmounts[..].pendingAssetAmount | |
| 58 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset epochRedeemAmounts[..].approvedAssetAmount | |
| 59 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user claim payment share amounts for an epoch is <= than the revoked share epochRedeemAmounts[..].pendingAssetAmount | |
| 60 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | pricePerShare never changes after a user operation | |
| 61 | doomsday_pricePerShare_never_changes_after_user_operation | implied pricePerShare (totalAssets / totalSupply) never changes after a user operation | |
| 62 | doomsday_impliedPricePerShare_never_changes_after_user_operation | accounting.accountValue should never revert | |
| 63 | hub_initializeLiability | After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance totalIssuance[..] is increased | |
| 64 | hub_setQueue | After FM performs approveRedeems and revokeShares with non-zero navPerShare, the total issuance totalIssuance[..] is decreased | |
| 65 | doomsday_deposit | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | |
| 66 | doomsday_deposit | user should always be able to mint less than maxMint | |
| 67 | doomsday_mint | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | |
| 68 | doomsday_mint | user should always be able to redeem less than maxWithdraw | |
| 69 | doomsday_redeem | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | |
| 70 | doomsday_redeem | user should always be able to withdraw less than maxWithdraw | |
| 71 | hub_createPool | After successfully calling claimDeposit for an investor (via notifyDeposit), their depositRequest[..].lastUpdate equals the nowDepositEpoch for the redeem | |
| 72 | hub_notifyDeposit | After successfully claimRedeem for an investor (via notifyRedeem), their depositRequest[..].lastUpdate equals the nowRedeemEpoch for the redemption | |
| 73 | token_approve | must revert if sending to or from a frozen user | |
| 74 | token_approve | must revert if sending to a non-member who is not endorsed | |
| 75 | _getTokenAndBalanceForVault | after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch | |
| 76 | _getTokenAndBalanceForVault | _updateDepositRequest should never revert due to underflow | |
| 77 | vault_requestDeposit | After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate equals nowRedeemEpoch | |
| 78 | vault_requestRedeem | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].lastUpdate equals the current nowDepositEpoch | |
| 79 | vault_requestRedeem | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending is zero | |
| 80 | vault_requestRedeem | cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow revert) | |
| 81 | vault_cancelDepositRequest | After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].lastUpdate equals the current nowRedeemEpoch | |
| 82 | vault_cancelDepositRequest | After successfully calling cancelRedeemRequest for an investor, their redeemRequest[..].pending is zero | |
| 83 | vault_cancelDepositRequest | cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow revert) | |
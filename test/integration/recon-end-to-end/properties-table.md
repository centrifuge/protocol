Status column: ✅ holds under fuzzing · ❌ known to break, see `.claude/docs/recon/13-acknowledged-risks.md`
· 📄 documented in the suite but not exercised by any handler.

| # | Function Name | Property Description | Passing |
|----|--------------|---------------------|----------|
| 1 | vault_maxDeposit | user can always maxDeposit if they have > 0 assets and are approved | ✅ |
| 2 | vault_maxDeposit | user can always deposit an amount between 1 and maxDeposit if they have > 0 assets and are approved | ✅ |
| 3 | vault_maxDeposit | maxDeposit should decrease by the amount deposited | ✅ |
| 4 | vault_maxDeposit | depositing maxDeposit blocks the user from depositing more | ✅ |
| 5 | vault_maxDeposit | depositing maxDeposit does not increase the pendingDeposit | ✅ |
| 6 | vault_maxDeposit | depositing maxDeposit doesn't mint more than maxMint shares | ✅ |
| 7 | vault_maxDeposit | For async vaults, validates PoolEscrow share transfers | ✅ |
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
| 19 | vault_sync_maxMint_no_overflow | SyncManager.maxMint never overflows uint128 | ✅ |
| 20 | vault_sync_maxDeposit_no_overflow | SyncManager.maxDeposit never results in shares exceeding uint128 | ✅ |
| 21 | vault_3 (erc7540_3) | 7540-3 convertToAssets(totalSupply) == totalAssets unless price is 0.0 | ✅ |
| 22 | vault_4 (erc7540_4) | 7540-4 convertToShares(totalAssets) == totalSupply unless price is 0.0 | ✅ |
| 23 | vault_5 (erc7540_5) | 7540-5 max* never reverts | ✅ |
| 24 | vault_6_deposit (erc7540_6) | 7540-6 claiming more than max deposit always reverts | ✅ |
| 25 | vault_6_mint (erc7540_6) | 7540-6 claiming more than max mint always reverts | ✅ |
| 26 | vault_6_withdraw (erc7540_6) | 7540-6 claiming more than max withdraw always reverts | ✅ |
| 27 | vault_6_redeem (erc7540_6) | 7540-6 claiming more than max redeem always reverts | ✅ |
| 28 | vault_7 (erc7540_7) | 7540-7 requestRedeem reverts if the share balance is less than amount | ✅ |
| 29 | vault_8 (erc7540_8) | 7540-8 preview* always reverts | ✅ |
| 30 | erc7540_9_deposit | 7540-9 if maxDeposit > 0, then deposit(max) should not revert — spec reference only, no `vault_9_*` wrapper is exposed | 📄 |
| 31 | erc7540_9_mint | 7540-9 if maxMint > 0, then mint(max) should not revert — spec reference only | 📄 |
| 32 | erc7540_9_withdraw | 7540-9 if maxWithdraw > 0, then withdraw(max) should not revert — spec reference only | 📄 |
| 33 | erc7540_9_redeem | 7540-9 if maxRedeem > 0, then redeem(max) should not revert — spec reference only | 📄 |
| 34 | property_sentinel_token_balance | Sentinel: current actor can reach a non-zero share balance | ✅ |
| 35 | property_sum_of_shares_received | Sum of share tokens received on `deposit` and `mint` <= sum of fulfilledDepositRequest.shares | ✅ |
| 36 | property_sum_of_assets_received | the sum of assets received on redeem and withdraw <= sum of payout of fulfilledRedeemRequest | ✅ |
| 37 | property_sum_of_pending_redeem_request | the payout of the escrow is always <= sum of redemptions paid out | ✅ |
| 38 | property_system_addresses_never_receive_share_tokens | System addresses should never receive share tokens | ✅ |
| 39 | property_sum_of_assets_received_on_claim_cancel_deposit_request_inductive | Sum of assets received on claimCancelDepositRequest <= sum of fulfillCancelDepositRequest.assets | ✅ |
| 40 | property_sum_of_received_leq_fulfilled_inductive | Claimable cancel redeem request delta equals escrow balance delta | ✅ |
| 41 | property_last_update_on_request_deposit | after successfully calling requestDeposit for an investor, their depositRequest[..].lastUpdate | ✅ |
| 42 | property_last_update_on_request_redeem | After successfully calling requestRedeem for an investor, their redeemRequest[..].lastUpdate equals nowRedeemEpoch | ✅ |
| 43 | property_share_balance_delta | user share balance correctly changes by the same amount of shares added to the escrow | ✅ |
| 44 | property_asset_balance_delta | user asset balance correctly changes by the same amount of assets added to the escrow | ✅ |
| 45 | property_deposit_share_balance_delta | user share balance correctly changes by the same amount of shares transferred from escrow on deposit/mint | ✅ |
| 46 | property_redeem_asset_balance_delta | user asset balance correctly changes by the same amount of assets transferred from pool escrow on redeem/withdraw | ✅ |
| 47 | property_sum_of_balances | Sum of balances equals total supply | ✅ |
| 48 | property_price_on_fulfillment | The price at which a user deposit is made is bounded by the price when the request was fulfilled | ✅ |
| 49 | property_price_on_redeem | The price at which a user redemption is made is bounded by the price when the request was fulfilled | ✅ |
| 50 | property_sum_of_possible_account_balances_leq_escrow | The sum of account balances is always <= the balance of the escrow | ✅ |
| 51 | property_sum_of_possible_account_balances_leq_escrow | The sum of max claimable shares is always <= the share balance of the escrow | ✅ |
| 52 | property_totalAssets_insolvency_only_increases | difference between totalAssets and actualAssets only increases | ✅ |
| 53 | property_soundness_processed_deposits | requested deposits must be >= the deposits fulfilled | ✅ |
| 54 | property_soundness_processed_redemptions | requested redemptions must be >= the redemptions fulfilled | ✅ |
| 55 | property_cancelled_soundness | requested deposits must be >= the fulfilled cancelled deposits | ✅ |
| 56 | property_cancelled_and_processed_deposits_soundness | requested deposits must be >= the fulfilled cancelled deposits + fulfilled deposits | ✅ |
| 57 | property_cancelled_and_processed_redemptions_soundness | requested redemptions must be >= the fulfilled cancelled redemptions + fulfilled redemptions | ✅ |
| 58 | property_solvency_deposit_requests | total deposits must be >= the approved deposits | ✅ |
| 59 | property_solvency_redemption_requests | total redemptions must be >= the approved redemptions | ✅ |
| 60 | property_actor_pending_and_queued_deposits | actor requested deposits - cancelled deposits - processed deposits = actor pending deposits + queued | ✅ |
| 61 | property_actor_pending_and_queued_redemptions | actor requested redemptions - cancelled redemptions - processed redemptions = actor pending redemptions + queued | ✅ |
| 62 | property_total_pending_and_approved | escrow total must be >= reserved; pending >= approved; price per share is admin-set | ✅ |
| 63 | property_sum_pending_user_deposit_geq_total_pending_deposit | The sum of pending user deposit amounts is always >= total pending deposit amount | ✅ |
| 64 | property_sum_pending_user_deposit_geq_total_pending_deposit | The total pending deposit amount is always >= the approved deposit amount | ✅ |
| 65 | property_sum_pending_user_redeem_geq_total_pending_redeem | The sum of pending user redeem amounts is always >= total pending redeem amount | ✅ |
| 66 | property_sum_pending_user_redeem_geq_total_pending_redeem | The total pending redeem amount is always >= the approved redeem amount | ✅ |
| 67 | property_epochId_can_increase_by_one_within_same_transaction | The epoch of a pool epochId[poolId] can increase at most by one within the same transaction | ✅ |
| 67a | property_epoch_pointer_ordering | BRM epoch pointers: issueEpoch <= depositEpoch and revokeEpoch <= redeemEpoch, always (EW5) | ✅ |
| 68 | property_decrease_valuation_no_increase_in_accountValue | account.totalDebit and account.totalCredit is always less than uint128(type(int128).max) | ✅ |
| 69 | property_decrease_valuation_no_increase_in_accountValue | Any decrease in valuation should not result in an increase in accountValue | ✅ |
| 70 | property_accounting_and_holdings_soundness | accountValue(assetAccount(assetId)) >= sum over share classes of holdings.value(poolId, scId, assetId): one asset account is shared by every share class holding that asset | ✅ |
| 70a | property_accounting_books_balance | Per pool, sum of account totalDebit equals sum of totalCredit (double-entry, lock()-enforced) (EW2) | ✅ |
| 70b | property_deficitCountMatchesHoldings | deficitCount(pool, share class, network) equals the number of holdings with decreasedAmount > increasedAmount, recomputed from holdingAmounts | ✅ |
| 70c | property_deficitCountMatchesHoldings | networkDeficitCount(pool, network) equals the sum of deficitCount over the network's share classes: the rollup a snapshot hook gates on never drifts from what it rolls up | ✅ |
| 71 | property_user_cannot_mutate_pending_redeem | A user cannot mutate their pending redeem amount if the epoch has not advanced | ✅ |
| 72 | property_additions_dont_cause_ppfs_loss | operations which increase deposits/shares don't decrease PPS | ✅ |
| 73 | property_removals_dont_cause_ppfs_loss | operations which remove deposits/shares don't decrease PPS | ✅ |
| 74 | property_additions_use_correct_price | If user deposits assets, they must always receive at least the pricePerShare | ✅ |
| 75 | property_removals_use_correct_price | If user redeems shares, they must always pay at least the pricePerShare | ✅ |
| 76 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user payoutShareAmount for an epoch is <= the number of issued shares | ✅ |
| 77 | property_eligible_user_deposit_amount_leq_deposit_issued_amount | The sum of eligible user payoutAssetAmount for an epoch is <= the number of issued asset amounts | ✅ |
| 78 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | The sum of eligible user claim payout asset amounts for an epoch is <= the approved asset amount | ✅ |
| 79 | property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount | The sum of eligible user claim payment share amounts for an epoch is <= the approved share amount | ✅ |
| 80 | property_shareQueueFlipLogic | Issue/Revoke Logic Correctness | ✅ |
| 81 | property_deltaCheck | Issue/Revoke Logic Correctness | ✅ |
| 82 | property_shareQueueFlipBoundaries | flips between positive and negative net positions are correctly detected | ✅ |
| 83 | property_shareQueueCommutativity | net position equals total issued minus total revoked (mathematical invariant) | ✅ |
| 84 | property_shareQueueSubmission | verifies queue submission logic and reset behavior | ✅ |
| 85 | property_shareQueueAssetCounter | Verifies that the asset counter accurately reflects non-empty asset queues | ✅ |
| 86 | property_assetQueueCounterConsistency | queuedAssetCounter matches the number of non-empty asset queues | ✅ |
| 87 | property_assetCounterBounds | queuedAssetCounter does not exceed total number of tracked assets | ✅ |
| 89 | property_nonceMonotonicity | Nonce strictly increases with each queue submission | ✅ |
| 91 | property_availableGtQueued | The balance sheet must always have sufficient balance for queued assets | ❌ |
| 92 | property_authorizationBypass | authorization checks can't be bypassed | ❌ |
| 93 | property_authorizationLevel | successful authorized calls must be made by authorized accounts | ✅ |
| 94 | property_authorizationChange | authorization changes are correctly tracked | ✅ |
| 95 | property_shareTransferRestrictions | Transfers from endorsed contracts are blocked | ✅ |
| 96 | property_shareTokenSupplyConsistency | Total supply equals sum of all tracked balances (actors + PoolEscrow) | ✅ |
| 97 | property_shareTokenCountedInSupply | share token should always be included if it's been supplied | ✅ |
| 98 | property_assetShareProportionalityDeposits | Asset-Share Proportionality on Deposits | ✅ |
| 99 | property_assetShareProportionalityWithdrawals | Asset-Share Proportionality on Withdrawals | ✅ |
| 100 | hub_issueShares | After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance increases | ✅ |
| 101 | hub_revokeShares | After FM performs approveRedeems and revokeShares with non-zero navPerShare, the total issuance decreases | ✅ |
| 102 | balanceSheet_noteDeposit | PoolEscrow.total increases by exactly the amount deposited | ✅ |
| 103 | balanceSheet_noteDeposit | PoolEscrow.reserved does not change during noteDeposit | ✅ |
| 104 | balanceSheet_withdraw | Withdrawals should not fail when there's sufficient balance | ✅ |
| 104a | balanceSheet_withdrawReserved | PoolEscrow.total and PoolEscrow.reserved both decrease by exactly the amount withdrawn | ✅ |
| 104b | balanceSheet_withdrawReserved | withdrawReserved does not queue a Hub holding decrease (already queued when reserved) | ✅ |
| 104c | balanceSheet_withdrawShares | withdrawShares moves shares out of the pool escrow with no change to queuedShares — handler is `internal`, reachable only via `balanceSheet_withdrawShares_clamped` or a reproducer | ✅ |
| 104d | property_escrowBalanceMatchesHoldingTotal | The pool escrow's raw token balance for an asset equals the sum of holding.total across share classes | ✅ |
| 104e | property_hubHoldingMatchesEscrowAccounted | Holdings conservation law: once the asset queue is drained, hub holdings.amount equals escrow accounted (total - reserved, floored at 0), exactly, incl. through over-reserve deficit excursions | ✅ |
| 104f | property_holdingZeroAmountHasZeroValue | A holding with zero derived amount carries zero value (no phantom NAV stranded on an emptied holding) | ✅ |
| 104g | hub_updateHoldingValue | Inline: immediately after update(), holdings.value equals getQuote(holdings.amount) (mark-to-market coherence) | ✅ |
| 104h | property_poolEscrowReservedSumConsistency | Per pool x scId, holding.reserved equals the sum of keyed reservedBy over ARM and both reasons (EW1) | ✅ |
| 105 | doomsday_mint | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | ✅ |
| 106 | doomsday_mint | user should always be able to deposit less than maxMint | ✅ |
| 107 | doomsday_mint | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | ✅ |
| 108 | doomsday_mint | user should always be able to mint less than maxMint | ✅ |
| 109 | doomsday_redeem | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | ✅ |
| 110 | doomsday_redeem | user should always be able to redeem less than maxWithdraw | ✅ |
| 111 | doomsday_withdraw | user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision | ✅ |
| 112 | doomsday_withdraw | user should always be able to withdraw less than maxWithdraw | ✅ |
| 113 | doomsday_pricePerShare_never_changes_after_user_operation | pricePerShare never changes after a user operation | ✅ |
| 114 | doomsday_impliedPricePerShare_never_changes_after_user_operation | implied pricePerShare (totalAssets / totalSupply) never changes after a user operation | ✅ |
| 115 | doomsday_accountValue | accounting.accountValue should never revert | ✅ |
| 116 | doomsday_zeroPrice_noPanics | System handles all operations gracefully at zero price | ✅ |
| 116a | doomsday_claimCancelDepositRequest_always_claimable | If claimableCancelDeposit > 0, the claim succeeds and pays exactly that amount (EW3, DOS) | ✅ |
| 116b | doomsday_claimCancelRedeemRequest_always_claimable | If claimableCancelRedeem > 0, the claim succeeds and returns exactly those shares (EW3, DOS) | ✅ |
| 117 | hub_notifyDeposit | After successfully calling claimDeposit for an investor (via notifyDeposit), their allocation decreases | ✅ |
| 118 | hub_notifyDeposit | PoolEscrow.total increases by exactly totalPaymentAssetAmount | ✅ |
| 119 | hub_notifyDeposit | PoolEscrow.reserved does not change during deposit processing | ✅ |
| 120 | hub_notifyRedeem | After successfully calling claimRedeem for an investor (via notifyRedeem), their allocation decreases | ✅ |
| 121 | token_transfer | must revert if sending to or from a frozen user | ✅ |
| 122 | token_transfer | must revert if sending to a non-member who is not endorsed | ✅ |
| 123 | token_transferFrom | must revert if sending to or from a frozen user | ✅ |
| 124 | token_transferFrom | must revert if sending to a non-member who is not endorsed | ✅ |
| 125 | vault_requestDeposit | _updateDepositRequest should never revert due to underflow | ✅ |
| 126 | vault_requestRedeem | sender or recipient can't be frozen for requested redemption | ✅ |
| 127 | vault_cancelDepositRequest | after successfully calling cancelDepositRequest for an investor, their claimable amount increases | ✅ |
| 128 | vault_cancelDepositRequest | after successfully calling cancelDepositRequest for an investor, their depositRequest[..].pending decreases | ✅ |
| 129 | vault_cancelDepositRequest | cancelDepositRequest absolute value should never be higher than pendingDeposit (would result in underflow) | ✅ |
| 130 | vault_cancelRedeemRequest | After successfully calling cancelRedeemRequest for an investor, their shares are returned | ✅ |
| 131 | vault_cancelRedeemRequest | cancelRedeemRequest absolute value should never be higher than pendingRedeem (would result in underflow) | ✅ |

## Changelog

### 2026-07-27 — merge of origin/main (v3.3 audit fixes, #254/#260/#264/#270)

Added: `property_deficitCountMatchesHoldings` (70b), from main's holdings-deficit-gate PR.

Handler surface changes:
* `hub_updateAssets` is now `internal` (reproducer/sanity only). It writes the hub ledger directly, which
  (a) desynchronises the hub snapshot nonce from `SnapshotQueue`'s, permanently reverting every later
  `submitQueued*` with `InvalidNonce`, and (b) moves `holdings.amount` with no matching escrow move, breaking
  104e. Its clamped variant was removed. The fuzzer reaches the same deficit state through
  `balanceSheet_overReserve_clamped` + `balanceSheet_submitQueuedAssets`, pinned by
  `CryticSanity.test_deficitCountMatchesHoldings_queueDriver`.
* ~~`spoke_deployAndLinkVault` resolves the deployed vault through the ERC-7575 pointer instead of the
  `DeployVault` log, so it needs no `recordLogs`/`getRecordedLogs` support from whichever fuzzer drives the suite.
  A deliberate divergence from main, which kept the log scan.~~ **Retracted 2026-08-04.** #296 deleted
  `_pointVault`, so there is no pointer to read; the handler now uses `IVaultFactory.getVault`. The
  cheatcode-independence argument stands, the mechanism does not.

Rows 30-33 re-marked 📄: the `vault_9_*` wrappers were deleted in the 2026-07-20 pass; the `erc7540_9_*`
bodies survive as spec documentation and are not exercised.

### 2026-07-20 — investment-flow gap additions (docs/invariant-gaps-investment-flow)

Added: `property_accounting_books_balance` (70a, EW2), `property_epoch_pointer_ordering`
(67a, EW5), `property_poolEscrowReservedSumConsistency` (104h, EW1),
`doomsday_claimCancelDepositRequest_always_claimable` / `_claimCancelRedeemRequest_`
(116a/116b, EW3), and inline post-flush zeroing asserts in `balanceSheet_submitQueuedAssets` /
`balanceSheet_submitQueuedShares` (EW6). Every addition passed a deliberate-falsification check.

Removed (vacuous — algebraically always true, zero signal):
* `property_reserveUnreserveBalanceIntegrity` (was 90) — asserted restatements of its own
  `total = available + reserved` definition; its `ghost_reserveIntegrityViolations` was written
  nowhere. Superseded by EW1 (104h), which reads the real keyed `reservedBy` ledger.
* `property_assetQueueNonNegative` (was 88) — asserted `uint128 >= 0`.

Not landed (unreachable in the synchronous same-chain harness): EW4 (cancel-flag-implies-pending)
and EW7 (request-while-cancel-pending reverts). Cancellations round-trip through the real
MessageDispatcher and fulfill synchronously inside the cancel call, so `pendingCancelDeposit/Redeem`
is never true at a property checkpoint — both properties would be always-true. See the gap-analysis
addendum (docs/notes/gap-analysis-2026-07-invariants-investment-flow.md §8).

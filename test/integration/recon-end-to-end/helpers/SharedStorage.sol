// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {ERC20} from "src/misc/ERC20.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

abstract contract SharedStorage {
    /**
     * GLOBAL SETTINGS
     */
    uint8 constant RECON_MODULO_DECIMALS = 19; // NOTE: Caps to 18

    // Reenable canary tests, to help determine if coverage goals are being met
    bool constant RECON_TOGGLE_CANARY_TESTS = false;

    // Properties we did not implement and we do not want that to be flagged
    bool RECON_SKIPPED_PROPERTY = true;

    // NOTE: This is to not clog up the logs
    bool TODO_RECON_SKIP_ERC7540 = false;

    // Prevent flagging of properties that have been acknowledged
    bool TODO_RECON_SKIP_ACKNOWLEDGED_CASES = true;

    // Disable them by setting this to false
    bool RECON_USE_SENTINEL_TESTS = false;

    // Gateway Mock
    bool RECON_USE_HARDCODED_DECIMALS = false; // Should we use random or hardcoded decimals?
    bool RECON_USE_SINGLE_DEPLOY = true; // NOTE: Actor Properties break if you use multi cause they are
    // mono-dimensional

    // TODO: This is broken rn
    // Liquidity Pool functions
    bool RECON_EXACT_BAL_CHECK = false;

    /// === INTERNAL COUNTERS === ///
    // Currency ID = Currency Length
    // Pool ID = Pool Length
    // Share ID = Share Length . toId
    uint64 ASSET_ID_COUNTER = 1;
    uint64 POOL_ID = 1;
    uint16 SHARE_COUNTER = 1;
    // Hash of index + salt, but we use number to be able to cycle
    bytes16 SHARE_ID = bytes16(bytes32(uint256(SHARE_COUNTER)));
    uint16 DEFAULT_DESTINATION_CHAIN = 1;
    uint128 ASSET_ID =
        uint128(
            bytes16(abi.encodePacked(DEFAULT_DESTINATION_CHAIN, uint32(1)))
        );

    // NOTE: TODO
    // ** INCOMPLETE - Deployment, Setup and Cycling of Assets, Shares, Pools and Vaults **/
    // Step 1
    /// TODO: Consider dropping
    mapping(address => uint128) assetAddressToAssetId;
    mapping(uint128 => address) assetIdToAssetAddress;

    // === invariant_E_1 === //
    // Currency
    // Indexed by Currency
    /**
     * See:
     *         - vault_requestDeposit
     */
    mapping(address => uint256) sumOfDepositRequests;
    /**
     * See:
     *         - invariant_asyncVault_9_r
     *         - invariant_asyncVault_9_w
     *         - vault_redeem
     *         - vault_withdraw
     */
    mapping(address => uint256) sumOfClaimedRedemptions;

    /**
     * See:
     *         - spoke_handleTransfer(bytes32 receiver, uint128 amount)
     *         - spoke_handleTransfer(address receiver, uint128 amount)
     *
     *         - spoke_transfer
     */
    mapping(address => uint256) sumOfTransfersIn;

    /**
     * See:
     *     -   spoke_handleTransfer
     */
    mapping(address => uint256) sumOfTransfersOut;

    // Global-1
    mapping(address => uint256) sumOfClaimedCancelledDeposits;
    // Global-2
    mapping(address => uint256) sumOfClaimedCancelledRedeemShares;

    // END === invariant_E_1 === //

    // UNSURE | TODO
    // Pretty sure I need to clamp by an amount sent by the user
    // Else they get like a bazillion tokens
    mapping(address => bool) hasRequestedDepositCancellation;
    mapping(address => bool) hasRequestedRedeemCancellation;

    // === invariant_E_2 === //
    // Share
    // Indexed by Share Token

    /**
     * // TODO: Jeroen to review!
     *     // NOTE This is basically an imaginary counter
     *     // It's not supposed to work this way in reality
     *     // TODO: MUST REMOVE
     *     See:
     *         - asyncRequests_fulfillCancelRedeemRequest
     *         - asyncRequests_fulfillRedeemRequest // NOTE: Used by E_1
     */
    mapping(address => uint256) sumOfWithdrawable;
    /**
     * See:
     *         - asyncRequests_fulfillDepositRequest
     */
    mapping(address => uint256) sumOfFulfilledDeposits;

    /**
     * See:
     *         -
     */
    mapping(address => uint256) sumOfClaimedDeposits;

    /**
     * See:
     *         - vault_requestRedeem
     *         - asyncRequests_triggerRedeemRequest
     */
    mapping(address => uint256) sumOfRedeemRequests;

    mapping(address asset => uint256) sumOfSyncDepositsAsset;
    mapping(address share => uint256) sumOfSyncDepositsShare;

    // END === invariant_E_2 === //

    // NOTE: OLD
    mapping(address => uint256) totalCurrenciesSent;
    mapping(address => uint256) totalShareSent;

    // These are used by invariant_global_3
    mapping(address => uint256) executedInvestments;
    mapping(address => uint256) executedRedemptions;

    mapping(address => uint256) incomingTransfers;
    mapping(address => uint256) outGoingTransfers;

    // NOTE: You need to decide if these should exist
    mapping(address => uint256) shareMints;

    // TODO: Global-1 and Global-2
    // Something is off
    /**
     * handleExecutedCollectInvest
     *     handleExecutedCollectRedeem
     */

    // Global-1
    mapping(address => uint256) claimedAmounts;

    // Global-2
    mapping(address => uint256) depositRequests;

    // Requests
    // NOTE: We need to store request data to be able to cap the values as otherwise the
    // System will enter an inconsistent state
    mapping(address => mapping(address => uint256)) requestDepositAssets;
    mapping(address => mapping(address => uint256)) requestRedeemShares;

    /// === GLOBAL GHOSTS === ///
    mapping(address => uint256) sumOfManagerDeposits;
    mapping(address => uint256) sumOfManagerWithdrawals;

    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userRequestDeposited;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userDepositProcessed;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userCancelledDeposits;

    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userRequestRedeemed;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userRequestRedeemedAssets;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userRedemptionsProcessed;
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256))) userCancelledRedeems;

    mapping(ShareClassId scId => mapping(AssetId assetId => uint256)) approvedDeposits;
    mapping(ShareClassId scId => mapping(AssetId assetId => uint256)) approvedRedemptions;

    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint256))) issuedHubShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => uint256)) issuedBalanceSheetShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint256))) revokedHubShares;
    mapping(PoolId poolId => mapping(ShareClassId scId => uint256)) revokedBalanceSheetShares;

    // ===============================
    // SHARE QUEUE GHOST VARIABLES
    // ===============================
    mapping(bytes32 => int256) public ghost_netSharePosition; // Net share position (positive for issuance, negative for revocation)
    mapping(bytes32 => uint256) public ghost_flipCount; // Count of position flips between issuance and revocation
    mapping(bytes32 => uint256) public ghost_totalIssued; // Total shares issued cumulatively
    mapping(bytes32 => uint256) public ghost_totalRevoked; // Total shares revoked cumulatively
    mapping(bytes32 => uint256) public ghost_assetQueueDeposits; // Cumulative deposits in asset queue
    mapping(bytes32 => uint256) public ghost_assetQueueWithdrawals; // Cumulative withdrawals in asset queue
    mapping(bytes32 => uint256) public ghost_shareQueueNonce; // Track nonce progression for share queue
    mapping(bytes32 => uint256) public ghost_assetCounterPerAsset; // For non-empty asset queues
    mapping(bytes32 => uint256) public ghost_previousNonce; // To verify monotonicity

    // Before/after state tracking for share queues
    mapping(bytes32 => uint128) public before_shareQueueDelta;
    mapping(bytes32 => bool) public before_shareQueueIsPositive;
    mapping(bytes32 => uint64) public before_nonce;

    // ===============================
    // RESERVE GHOST VARIABLES
    // ===============================
    mapping(bytes32 => uint256) public ghost_totalReserveOperations;
    mapping(bytes32 => uint256) public ghost_totalUnreserveOperations;
    mapping(bytes32 => uint256) public ghost_netReserved;
    mapping(bytes32 => bool) public ghost_reserveOverflow;
    mapping(bytes32 => bool) public ghost_reserveUnderflow;
    mapping(bytes32 => uint256) public ghost_reserveIntegrityViolations;

    // ===============================
    // AUTHORIZATION GHOST VARIABLES
    // ===============================
    enum AuthLevel {
        NONE,
        MANAGER,
        WARD
    }
    mapping(address => AuthLevel) public ghost_authorizationLevel;
    mapping(bytes32 => uint256) public ghost_unauthorizedAttempts;
    mapping(bytes32 => uint256) public ghost_privilegedOperationCount;
    mapping(bytes32 => address) public ghost_lastAuthorizedCaller;
    mapping(address => uint256) public ghost_authorizationChanges;
    mapping(bytes32 => bool) public ghost_authorizationBypass;

    // ===============================
    // TRANSFER RESTRICTION GHOST VARIABLES
    // ===============================
    mapping(address => bool) public ghost_isEndorsedContract;
    mapping(bytes32 => uint256) public ghost_endorsedTransferAttempts;
    mapping(bytes32 => uint256) public ghost_blockedEndorsedTransfers;
    mapping(bytes32 => uint256) public ghost_validTransferCount;
    mapping(bytes32 => address) public ghost_lastTransferFrom;
    mapping(address => uint256) public ghost_endorsementChanges;

    // ===============================
    // SUPPLY CONSISTENCY GHOST VARIABLES
    // ===============================
    mapping(bytes32 => uint256) public ghost_totalShareSupply;
    mapping(bytes32 => mapping(address => uint256))
        public ghost_individualBalances;
    mapping(bytes32 => uint256) public ghost_supplyMintEvents;
    mapping(bytes32 => uint256) public ghost_supplyBurnEvents;
    mapping(bytes32 => bool) public ghost_supplyOperationOccurred;

    // ===============================
    // ASSET PROPORTIONALITY GHOST VARIABLES
    // ===============================
    // Deposit proportionality tracking
    mapping(bytes32 => uint256) public ghost_cumulativeAssetsDeposited;
    mapping(bytes32 => uint256) public ghost_cumulativeSharesIssuedForDeposits;
    mapping(bytes32 => uint256) public ghost_depositExchangeRate;
    mapping(bytes32 => bool) public ghost_depositProportionalityTracked;

    // Withdrawal proportionality tracking
    mapping(bytes32 => uint256) public ghost_cumulativeAssetsWithdrawn;
    mapping(bytes32 => uint256)
        public ghost_cumulativeSharesRevokedForWithdrawals;
    mapping(bytes32 => bool) public ghost_withdrawalProportionalityTracked;

    // ===============================
    // ESCROW SUFFICIENCY TRACKING
    // ===============================
    mapping(bytes32 => uint256) public ghost_escrowReservedBalance;
    mapping(bytes32 => uint256) public ghost_escrowAvailableBalance;
    mapping(bytes32 => bool) public ghost_escrowSufficiencyTracked;
}

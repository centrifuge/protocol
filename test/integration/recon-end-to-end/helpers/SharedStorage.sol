// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

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
    bool RECON_SKIP_ERC7540 = false;

    // Prevent flagging of properties that have been acknowledged
    bool RECON_SKIP_ACKNOWLEDGED_CASES = true;

    // Disable them by setting this to false
    bool RECON_USE_SENTINEL_TESTS = false;

    // Gateway Mock
    bool RECON_USE_HARDCODED_DECIMALS = false; // Should we use random or hardcoded decimals?
    bool RECON_USE_SINGLE_DEPLOY = true; // NOTE: Actor Properties break if you use multi cause they are
    // mono-dimensional

    /**
     * @notice Enable exact balance checking for liquidity pool operations
     * @dev Disabled due to rounding errors in PoolEscrow balance tracking.
     *      Enabling requires precision fixes in pool balance calculations.
     */
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
    uint128 ASSET_ID = uint128(bytes16(abi.encodePacked(DEFAULT_DESTINATION_CHAIN, uint32(1))));

    /**
     * @notice Bidirectional mapping between asset addresses and AssetId
     * @dev Used for asset ID resolution during deployment and handler operations.
     *      Duplicates spoke.assetToId() but provides faster lookups for handlers.
     */
    mapping(address => uint128) assetAddressToAssetId;
    mapping(uint128 => address) assetIdToAssetAddress;

    // ═══════════════════════════════════════════════════════════════
    // ASSET FLOW TRACKING
    // ═══════════════════════════════════════════════════════════════
    // Tracks the movement of assets (currencies) through the protocol:
    //   - Deposit requests, redemption claims, transfers
    //   - Used by: property_sum_of_assets_received, property_sum_of_pending_redeem_request
    // Indexed by asset address

    /**
     * @notice Total assets requested for deposit across all actors
     * @dev Updated by: vault_requestDeposit
     */
    mapping(address => uint256) sumOfDepositRequests;

    /**
     * @notice Total assets claimed from redemptions (withdraw/redeem calls)
     * @dev Updated by: vault_withdraw, vault_redeem (ERC7540Properties)
     *      Used by: property_sum_of_assets_received, property_sum_of_pending_redeem_request
     */
    mapping(address => uint256) sumOfClaimedRedemptions;

    /**
     * @notice Total assets transferred into the protocol via spoke
     * @dev Updated by: spoke_handleTransfer, spoke_transfer
     */
    mapping(address => uint256) sumOfTransfersIn;

    /**
     * @notice Total assets transferred out of the protocol via spoke
     * @dev Updated by: spoke_handleTransfer
     */
    mapping(address => uint256) sumOfTransfersOut;

    /**
     * @notice Total assets returned from cancelled deposit requests
     * @dev Updated by: vault claim cancel deposit operations
     */
    mapping(address => uint256) sumOfClaimedCancelledDeposits;

    // END === ASSET FLOW TRACKING === //

    // ═══════════════════════════════════════════════════════════════
    // SHARE TOKEN FLOW TRACKING
    // ═══════════════════════════════════════════════════════════════
    // Tracks share token issuance, claims, and withdrawable balances
    //   - Used by: property_sum_of_shares_received, property_sum_of_assets_received
    // Indexed by share token address (or asset address for withdrawable amounts)

    /**
     * @notice Tracks cumulative withdrawable assets from fulfilled redemptions
     * @dev Incremented when hub_notifyRedeem processes redemptions and increases
     *      user's maxWithdraw allocation.
     *
     * Note: Bridges asset tracking (E_1 concept) and share tracking (E_2 concept)
     *       because it represents withdrawable assets resulting from share redemptions.
     *
     * Updated by:
     *   - hub_notifyRedeem → _updateRedeemGhostVariables (HubTargets.sol:211, 513)
     * Used by:
     *   - property_sum_of_assets_received (Properties.sol:87)
     */
    mapping(address => uint256) sumOfWithdrawable;

    /**
     * @notice Total shares made available from fulfilled deposit requests
     * @dev Updated by: hub_notifyDeposit operations
     *      Used by: property_sum_of_shares_received
     */
    mapping(address => uint256) sumOfFulfilledDeposits;

    /**
     * @notice Total shares actually claimed by users (deposit/mint calls)
     * @dev Updated by: vault deposit/mint operations
     *      Used by: property_sum_of_shares_received
     */
    mapping(address => uint256) sumOfClaimedDeposits;

    /**
     * @notice Total shares requested for redemption
     * @dev Updated by: vault_requestRedeem
     */
    mapping(address => uint256) sumOfRedeemRequests;

    /**
     * @notice Sync vault deposit tracking (assets and shares)
     * @dev Updated by: sync vault deposit operations
     */
    mapping(address asset => uint256) sumOfSyncDepositsAsset;
    mapping(address share => uint256) sumOfSyncDepositsShare;

    // END === SHARE TOKEN FLOW TRACKING === //

    // ═══════════════════════════════════════════════════════════════
    // ADDITIONAL GHOST VARIABLES
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Tracks net share balance sent via spoke transfers
     * @dev Decremented when shares are transferred out via spoke
     *      Used by: Properties._decreaseTotalShareSent
     */
    mapping(address => uint256) totalShareSent;

    /**
     * @notice Tracks executed investment operations (share minting from deposits)
     * @dev Incremented when deposits/mints result in share issuance:
     *        - vault_deposit_sync
     *        - hub_issue
     */
    mapping(address => uint256) executedInvestments;

    /**
     * @notice Tracks executed redemption operations (share burning from withdrawals)
     * @dev Incremented when redemptions result in share burning:
     *        - hub_revoke
     */
    mapping(address => uint256) executedRedemptions;

    /**
     * @notice Net share mints tracked through BalanceSheet operations
     * @dev Incremented on issue(), decremented on revoke()
     *      Used by: balanceSheet_issue, balanceSheet_revoke
     */
    mapping(address => uint256) shareMints;

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
    mapping(ShareClassId scId => mapping(AssetId assetId => mapping(address user => uint256)))
        userRequestRedeemedAssets;
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
    mapping(bytes32 => int256) internal ghost_netSharePosition; // Net share position (positive for issuance, negative for revocation)
    mapping(bytes32 => uint256) internal ghost_flipCount; // Count of position flips between issuance and revocation
    mapping(bytes32 => uint256) internal ghost_totalIssued; // Total shares issued cumulatively
    mapping(bytes32 => uint256) internal ghost_totalRevoked; // Total shares revoked cumulatively
    mapping(bytes32 => uint256) internal ghost_assetQueueDeposits; // Cumulative deposits in asset queue
    mapping(bytes32 => uint256) internal ghost_assetQueueWithdrawals; // Cumulative withdrawals in asset queue
    mapping(bytes32 => uint256) internal ghost_shareQueueNonce; // Track nonce progression for share queue
    mapping(bytes32 => uint256) internal ghost_previousNonce; // To verify monotonicity

    // Before/after state tracking for share queues
    mapping(bytes32 => uint128) internal before_shareQueueDelta;
    mapping(bytes32 => bool) internal before_shareQueueIsPositive;
    mapping(bytes32 => uint64) internal before_nonce;

    // ===============================
    // RESERVE GHOST VARIABLES
    // ===============================
    mapping(bytes32 => uint256) internal ghost_totalReserveOperations;
    mapping(bytes32 => uint256) internal ghost_totalUnreserveOperations;
    mapping(bytes32 => uint256) internal ghost_netReserved;
    mapping(bytes32 => uint256) internal ghost_reserveIntegrityViolations;

    // ===============================
    // AUTHORIZATION GHOST VARIABLES
    // ===============================
    enum AuthLevel {
        NONE,
        MANAGER,
        WARD
    }
    mapping(address => AuthLevel) internal ghost_authorizationLevel;
    mapping(bytes32 => uint256) internal ghost_unauthorizedAttempts;
    mapping(bytes32 => uint256) internal ghost_privilegedOperationCount;
    mapping(bytes32 => address) internal ghost_lastAuthorizedCaller;
    mapping(address => uint256) internal ghost_authorizationChanges;
    mapping(bytes32 => bool) internal ghost_authorizationBypass;

    // ===============================
    // TRANSFER RESTRICTION GHOST VARIABLES
    // ===============================
    mapping(address => bool) internal ghost_isEndorsedContract;
    mapping(bytes32 => uint256) internal ghost_endorsedTransferAttempts;
    mapping(bytes32 => uint256) internal ghost_blockedEndorsedTransfers;
    mapping(bytes32 => uint256) internal ghost_validTransferCount;
    mapping(bytes32 => address) internal ghost_lastTransferFrom;
    mapping(address => uint256) internal ghost_endorsementChanges;

    // ===============================
    // SUPPLY CONSISTENCY GHOST VARIABLES
    // ===============================
    mapping(bytes32 => uint256) internal ghost_totalShareSupply;
    mapping(bytes32 => uint256) internal ghost_supplyMintEvents;
    mapping(bytes32 => uint256) internal ghost_supplyBurnEvents;
    mapping(bytes32 => bool) internal ghost_supplyOperationOccurred;

    // ===============================
    // ASSET PROPORTIONALITY GHOST VARIABLES
    // ===============================
    // Deposit proportionality tracking
    mapping(bytes32 => uint256) internal ghost_cumulativeAssetsDeposited;
    mapping(bytes32 => uint256) internal ghost_cumulativeSharesIssuedForDeposits;
    mapping(bytes32 => uint256) internal ghost_depositExchangeRate;
    mapping(bytes32 => bool) internal ghost_depositProportionalityTracked;

    // Withdrawal proportionality tracking
    mapping(bytes32 => uint256) internal ghost_cumulativeAssetsWithdrawn;
    mapping(bytes32 => uint256) internal ghost_cumulativeSharesRevokedForWithdrawals;
    mapping(bytes32 => bool) internal ghost_withdrawalProportionalityTracked;

    // ===============================
    // ESCROW SUFFICIENCY TRACKING
    // ===============================
    mapping(bytes32 => uint256) internal ghost_escrowReservedBalance;
    mapping(bytes32 => uint256) internal ghost_escrowAvailableBalance;
    mapping(bytes32 => bool) internal ghost_escrowSufficiencyTracked;
}

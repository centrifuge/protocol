// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {ERC20} from "src/misc/ERC20.sol";

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
    uint128 ASSET_ID = uint128(bytes16(abi.encodePacked(DEFAULT_DESTINATION_CHAIN, uint32(1))));

    // NOTE: TODO
    // ** INCOMPLETE - Deployment, Setup and Cycling of Assets, Shares, Pools and Vaults **/
    // Step 1
    /// TODO: Consider dropping
    mapping(address => uint128) assetAddressToAssetId;
    mapping(uint128 => address) assetIdToAssetAddress;

    // TODO: Consider refactoring to a address of Currency or Share to get the rest of the details
    address[] shareClassTokens; // TODO: Share to ID
    address[] vaults; // TODO: Liquidity To ID?

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
    mapping(address => uint256) cancelRedeemShareTokenPayout;
    // Global-2
    mapping(address => uint256) cancelDepositCurrencyPayout;

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
    mapping(address => uint256) mintedByCurrencyPayout;
    /**
     * See:
     *         - asyncRequests_fulfillDepositRequest
     */
    mapping(address => uint256) sumOfFullfilledDeposits;

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

    /**
     * See:
     *         - asyncRequests_fulfillRedeemRequest
     */
    mapping(address => uint256) sumOfClaimedRequests;

    mapping(address => uint256) sumOfClaimedDepositCancelations;
    mapping(address => uint256) sumOfClaimedRedeemCancelations;

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
}

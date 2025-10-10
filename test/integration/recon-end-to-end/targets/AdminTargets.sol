// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId, newAssetId} from "src/core/types/AssetId.sol";
import {JournalEntry} from "src/core/hub/interfaces/IAccounting.sol";
import {IValuation} from "src/core/hub/interfaces/IValuation.sol";
import {AccountId} from "src/core/types/AccountId.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {PoolId} from "src/core/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MAX_MESSAGE_COST} from "src/core/messaging/interfaces/IGasService.sol";
import {PricingLib} from "src/core/libraries/PricingLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {EpochInvestAmounts, EpochRedeemAmounts} from "src/vaults/interfaces/IBatchRequestManager.sol";

// Test Utils
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";

/// @dev Admin functions called by the admin actor
/// @dev These explicitly clamp the investor to always be one of the actors
abstract contract AdminTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// @dev Helper to calculate issued shares to avoid stack depth issues
    function _calculateIssuedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint32 nowIssueEpochId,
        uint128 navPerShare
    ) private view returns (uint128) {
        // First, just get the approved asset amount and price
        (
            ,  // approvedPoolAmount
            uint128 approvedAssetAmount,
            ,  // pendingAssetAmount
            D18 pricePoolPerAsset,
            ,  // pricePoolPerShare
               // issuedAt
        ) = batchRequestManager.epochInvestAmounts(poolId, scId, assetId, nowIssueEpochId);

        if (navPerShare == 0 || !pricePoolPerAsset.isNotZero()) {
            return 0;
        }

        // Calculate in separate step to avoid stack depth
        return PricingLib.assetToShareAmount(
            approvedAssetAmount,
            hubRegistry.decimals(assetId),
            hubRegistry.decimals(poolId),
            pricePoolPerAsset,
            D18.wrap(navPerShare),
            MathLib.Rounding.Down
        );
    }

    /// @dev Helper to calculate revoked shares to avoid stack depth issues
    function _calculateRevokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint32 nowRevokeEpochId
    ) private view returns (uint128) {
        (
            uint128 approvedShareAmount,
            uint128 pendingShareAmount,
            D18 pricePoolPerAsset,
            D18 pricePoolPerShareEpoch,
            uint128 payoutAssetAmountEpoch,
            uint64 revokedAt
        ) = batchRequestManager.epochRedeemAmounts(poolId, scId, payoutAssetId, nowRevokeEpochId);

        // Return the approved share amount which represents the revoked shares
        return approvedShareAmount;
    }


    /// === SyncManager === ///
    function syncManager_setValuation(address valuation) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        syncManager.setValuation(poolId, scId, valuation);
    }

    function syncManager_setValuation_clamped(bool isIdentityValuation) public {
        address valuation = isIdentityValuation
            ? address(identityValuation)
            : address(transientValuation);
        syncManager_setValuation(valuation);
    }

    // === Hub === ///
    function hub_addShareClass(uint256 salt) public updateGhosts {
        PoolId poolId = _getPool();
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";

        // Track authorization - addShareClass requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        hub.addShareClass(poolId, name, symbol, bytes32(salt));
    }

    function hub_approveDeposits(
        uint32 nowDepositEpochId,
        uint128 maxApproval
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId paymentAssetId = _getAssetId();
        uint128 pendingDepositBefore = batchRequestManager.pendingDeposit(
            poolId,
            scId,
            paymentAssetId
        );

        batchRequestManager.approveDeposits{value: MAX_MESSAGE_COST}(
            poolId,
            scId,
            paymentAssetId,
            nowDepositEpochId,
            maxApproval,
            D18.wrap(1e18), // pricePoolPerAsset - 1:1 price
            address(this) // refund
        );

        uint128 pendingDepositAfter = batchRequestManager.pendingDeposit(
            poolId,
            scId,
            paymentAssetId
        );
        uint128 approvedAssetAmount = pendingDepositBefore -
            pendingDepositAfter;
        approvedDeposits[scId][paymentAssetId] += approvedAssetAmount;
    }

    function hub_approveRedeems(
        uint32 nowRedeemEpochId,
        uint128 maxApproval
    ) public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId payoutAssetId = _getAssetId();
        uint128 pendingRedeemBefore = batchRequestManager.pendingRedeem(
            poolId,
            scId,
            payoutAssetId
        );

        batchRequestManager.approveRedeems{value: MAX_MESSAGE_COST}(
            poolId,
            scId,
            payoutAssetId,
            nowRedeemEpochId,
            maxApproval,
            D18.wrap(1e18) // pricePoolPerAsset - 1:1 price
        );

        uint128 pendingRedeemAfter = batchRequestManager.pendingRedeem(
            poolId,
            scId,
            payoutAssetId
        );
        uint128 approvedAssetAmount = pendingRedeemBefore - pendingRedeemAfter;
        approvedRedemptions[scId][payoutAssetId] += approvedAssetAmount;
    }

    function hub_approveRedeems_clamped(
        uint32 nowRedeemEpochId,
        uint128 maxApproval
    ) public {
        hub_approveRedeems(nowRedeemEpochId, maxApproval);
    }

    function hub_createAccount(
        uint32 accountAsInt,
        bool isDebitNormal
    ) public updateGhosts {
        PoolId poolId = _getPool();
        AccountId account = AccountId.wrap(accountAsInt);

        // Track authorization - createAccount requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        hub.createAccount(poolId, account, isDebitNormal);

        createdAccountIds.push(account);
    }

    function hub_initializeHolding(
        IValuation valuation,
        uint32 assetAccountAsUint,
        uint32 equityAccountAsUint,
        uint32 lossAccountAsUint,
        uint32 gainAccountAsUint
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();

        // Track authorization - initializeHolding requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        hub.initializeHolding(
            poolId,
            scId,
            assetId,
            valuation,
            AccountId.wrap(assetAccountAsUint),
            AccountId.wrap(equityAccountAsUint),
            AccountId.wrap(lossAccountAsUint),
            AccountId.wrap(gainAccountAsUint)
        );
    }

    function hub_initializeHolding_clamped(
        bool isIdentityValuation,
        uint8 assetAccountEntropy,
        uint8 equityAccountEntropy,
        uint8 lossAccountEntropy,
        uint8 gainAccountEntropy
    ) public {
        IValuation valuation = isIdentityValuation
            ? IValuation(address(identityValuation))
            : IValuation(address(transientValuation));
        AccountId assetAccount = Helpers.getRandomAccountId(
            createdAccountIds,
            assetAccountEntropy
        );
        AccountId equityAccount = Helpers.getRandomAccountId(
            createdAccountIds,
            equityAccountEntropy
        );
        AccountId lossAccount = Helpers.getRandomAccountId(
            createdAccountIds,
            lossAccountEntropy
        );
        AccountId gainAccount = Helpers.getRandomAccountId(
            createdAccountIds,
            gainAccountEntropy
        );

        hub_initializeHolding(
            valuation,
            uint32(assetAccount.raw()),
            uint32(equityAccount.raw()),
            uint32(lossAccount.raw()),
            uint32(gainAccount.raw())
        );
    }

    function hub_initializeLiability(
        IValuation valuation,
        uint32 expenseAccountAsUint,
        uint32 liabilityAccountAsUint
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();

        // Track authorization - initializeLiability requires authOrManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        hub.initializeLiability(
            poolId,
            scId,
            assetId,
            valuation,
            AccountId.wrap(expenseAccountAsUint),
            AccountId.wrap(liabilityAccountAsUint)
        );
    }

    function hub_initializeLiability_clamped(
        bool isIdentityValuation,
        uint8 expenseAccountEntropy,
        uint8 liabilityAccountEntropy
    ) public {
        IValuation valuation = isIdentityValuation
            ? IValuation(address(identityValuation))
            : IValuation(address(transientValuation));
        AccountId expenseAccount = Helpers.getRandomAccountId(
            createdAccountIds,
            expenseAccountEntropy
        );
        AccountId liabilityAccount = Helpers.getRandomAccountId(
            createdAccountIds,
            liabilityAccountEntropy
        );

        hub_initializeLiability(
            valuation,
            uint32(expenseAccount.raw()),
            uint32(liabilityAccount.raw())
        );
    }

    /// @dev Property: After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance
    /// totalIssuance[..] is increased
    // TODO: Refactor this property to work with new issuance update logic
    function hub_issueShares(
        uint32 nowIssueEpochId,
        uint128 navPerShare
    ) public updateGhostsWithType(OpType.ADD) {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();
        uint256 escrowSharesBefore = IShareToken(_getShareToken()).balanceOf(
            address(globalEscrow)
        );

        batchRequestManager.issueShares{value: MAX_MESSAGE_COST}(
            poolId,
            scId,
            assetId,
            nowIssueEpochId,
            D18.wrap(navPerShare),
            SHARE_HOOK_GAS,
            _getActor()
        );

        // Calculate issued amount in separate function to avoid stack depth
        uint128 issuedShareAmount = _calculateIssuedShares(
            poolId,
            scId,
            assetId,
            nowIssueEpochId,
            navPerShare
        );

        uint256 escrowSharesAfter = IShareToken(_getShareToken()).balanceOf(
            address(globalEscrow)
        );

        uint256 escrowShareDelta = escrowSharesAfter - escrowSharesBefore;
        executedInvestments[_getShareToken()] += escrowShareDelta;
        sumOfFulfilledDeposits[_getShareToken()] += escrowShareDelta;
        issuedHubShares[poolId][scId][assetId] += issuedShareAmount;

        // Update ghost variables for share queue tracking
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        ghost_totalIssued[shareKey] += issuedShareAmount;
        ghost_netSharePosition[shareKey] += int256(uint256(issuedShareAmount));

        // Check for share queue flip
        (uint128 deltaAfter, bool isPositiveAfter, , ) = balanceSheet
            .queuedShares(poolId, scId);
        bytes32 key = _poolShareKey(poolId, scId);
        uint128 deltaBefore = before_shareQueueDelta[key];
        bool isPositiveBefore = before_shareQueueIsPositive[key];

        if (
            (isPositiveBefore != isPositiveAfter) &&
            (deltaBefore != 0 || deltaAfter != 0)
        ) {
            ghost_flipCount[shareKey]++;
        }

        // TODO: Refactor this to work with new issuance update logic
        // if(navPerShare > 0) {
        //     gt(totalIssuanceAfter, totalIssuanceBefore, "total issuance is not increased after issueShares");
        // }
    }

    function hub_issueShares_clamped(
        uint32 nowIssueEpochId,
        uint128 navPerShare
    ) public {
        hub_issueShares(nowIssueEpochId, navPerShare);
    }

    function hub_notifyPool(uint16 centrifugeId) public updateGhosts {
        PoolId poolId = _getPool();
        hub.notifyPool{value: MAX_MESSAGE_COST}(poolId, centrifugeId, _getActor());
    }

    function hub_notifyPool_clamped() public {
        hub_notifyPool(CENTRIFUGE_CHAIN_ID);
    }

    function hub_notifyShareClass(
        uint16 centrifugeId,
        uint256 hookAsUint
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        hub.notifyShareClass{value: MAX_MESSAGE_COST}(poolId, scId, centrifugeId, bytes32(hookAsUint), _getActor());
    }

    function hub_notifyShareClass_clamped(uint256 hookAsUint) public {
        hub_notifyShareClass(CENTRIFUGE_CHAIN_ID, hookAsUint);
    }

    function hub_notifySharePrice(
        uint16 centrifugeId
    ) public updateGhostsWithType(OpType.UPDATE) {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        hub.notifySharePrice{value: MAX_MESSAGE_COST}(poolId, scId, centrifugeId, _getActor());
    }

    function hub_notifySharePrice_clamped() public {
        hub_notifySharePrice(CENTRIFUGE_CHAIN_ID);
    }

    function hub_notifyAssetPrice() public updateGhostsWithType(OpType.ADMIN) {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();
        hub.notifyAssetPrice{value: MAX_MESSAGE_COST}(poolId, scId, assetId, _getActor());
    }

    /// @dev Property: After FM performs approveRedeems and revokeShares with non-zero navPerShare, the total issuance
    /// totalIssuance[..] is decreased
    // TODO: Refactor this property to work with new issuance update logic
    function hub_revokeShares(
        uint32 nowRevokeEpochId,
        uint128 navPerShare
    ) public updateGhostsWithType(OpType.REMOVE) {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId payoutAssetId = _getAssetId();
        uint256 sharesBefore = IShareToken(_getShareToken()).balanceOf(
            address(globalEscrow)
        );

        batchRequestManager.revokeShares{value: MAX_MESSAGE_COST}(
            poolId,
            scId,
            payoutAssetId,
            nowRevokeEpochId,
            D18.wrap(navPerShare),
            SHARE_HOOK_GAS,
            _getActor()
        );

        // Get and process epoch data in separate function to avoid stack depth
        uint128 revokedShareAmount = _calculateRevokedShares(
            poolId,
            scId,
            payoutAssetId,
            nowRevokeEpochId
        );

        uint256 sharesAfter = IShareToken(_getShareToken()).balanceOf(
            address(globalEscrow)
        );
        uint256 burnedShares = sharesBefore - sharesAfter;

        // NOTE: shares are burned on revoke
        executedRedemptions[vault.share()] += burnedShares;
        revokedHubShares[poolId][scId][payoutAssetId] += revokedShareAmount;

        // Update ghost variables for share queue tracking
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        ghost_totalRevoked[shareKey] += revokedShareAmount;
        ghost_netSharePosition[shareKey] -= int256(uint256(revokedShareAmount));

        // Check for share queue flip
        (uint128 deltaAfter, bool isPositiveAfter, , ) = balanceSheet
            .queuedShares(poolId, scId);
        bytes32 key = _poolShareKey(poolId, scId);
        uint128 deltaBefore = before_shareQueueDelta[key];
        bool isPositiveBefore = before_shareQueueIsPositive[key];

        if (
            (isPositiveBefore != isPositiveAfter) &&
            (deltaBefore != 0 || deltaAfter != 0)
        ) {
            ghost_flipCount[shareKey]++;
        }

        // if(navPerShare > 0) {
        //     lt(totalIssuanceAfter, totalIssuanceBefore, "total issuance is not decreased after revokeShares");
        // }
    }

    function hub_setAccountMetadata(
        uint32 accountAsInt,
        uint256 metadataAsUint
    ) public updateGhosts {
        PoolId poolId = _getPool();
        AccountId account = AccountId.wrap(accountAsInt);
        bytes memory metadata = abi.encodePacked(metadataAsUint);
        hub.setAccountMetadata(poolId, account, metadata);
    }

    // NOTE: removed because it introduces too many false positives with no added benefit
    // function hub_setHoldingAccountId(
    //     uint128 assetIdAsUint,
    //     uint8 kind,
    //     uint32 accountIdAsInt
    // ) public updateGhosts {
    //     PoolId poolId = _getPool();
    //     ShareClassId scId = _getShareClassId();
    //     AssetId assetId = AssetId.wrap(assetIdAsUint);
    //     AccountId accountId = AccountId.wrap(accountIdAsInt);
    //     hub.setHoldingAccountId(poolId, scId, assetId, kind, accountId);
    // }

    // function hub_setHoldingAccountId_clamped(
    //     uint128 assetIdAsUint,
    //     uint8 kind,
    //     uint32 accountIdAsInt
    // ) public updateGhosts {
    //     PoolId poolId = _getPool();
    //     ShareClassId scId = _getShareClassId();
    //     AssetId assetId = _getAssetId();

    //     accountIdAsInt %= 5; // 4 possible accountId types in Setup
    //     AccountId accountId = AccountId.wrap(accountIdAsInt);
    //     hub.setHoldingAccountId(poolId, scId, assetId, kind, accountId);
    // }

    function hub_setPoolMetadata(uint256 metadataAsUint) public updateGhosts {
        PoolId poolId = _getPool();
        bytes memory metadata = abi.encodePacked(metadataAsUint);
        hub.setPoolMetadata(poolId, metadata);
    }

    function hub_updateHoldingValuation(
        uint128 assetIdAsUint,
        IValuation valuation
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
    }

    function hub_updateHoldingValuation_clamped(
        bool isIdentityValuation
    ) public {
        AssetId assetId = _getAssetId();
        IValuation valuation = isIdentityValuation
            ? IValuation(address(identityValuation))
            : IValuation(address(transientValuation));
        hub_updateHoldingValuation(assetId.raw(), valuation);
    }

    function hub_updateHoldingIsLiability(
        uint128 assetIdAsUint,
        bool isLiability
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingIsLiability(poolId, scId, assetId, isLiability);
    }

    function hub_updateHoldingIsLiability_clamped(bool isLiability) public {
        hub_updateHoldingIsLiability(_getAssetId().raw(), isLiability);
    }

    function hub_updateRestriction(
        uint16 chainId,
        uint256 payloadAsUint
    ) public updateGhosts {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        bytes memory payload = abi.encodePacked(payloadAsUint);
        hub.updateRestriction{value: MAX_MESSAGE_COST}(poolId, scId, chainId, payload, 0, _getActor());
    }

    function hub_updateRestriction_clamped(uint256 payloadAsUint) public {
        hub_updateRestriction(CENTRIFUGE_CHAIN_ID, payloadAsUint);
    }

    function hub_updateSharePrice(
        uint64,
        /* poolIdAsUint */ uint128,
        /* scIdAsUint */ uint128 navPoolPerShare
    ) public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.updateSharePrice{value: MAX_MESSAGE_COST}(poolId, scId, D18.wrap(navPoolPerShare), uint64(block.timestamp));
    }

    function hub_forceCancelDepositRequest() public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes32 investor = _getActor().toBytes32();
        AssetId depositAssetId = _getAssetId();

        batchRequestManager.forceCancelDepositRequest{value: MAX_MESSAGE_COST}(poolId, scId, investor, depositAssetId, _getActor());
    }

    function hub_forceCancelRedeemRequest() public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes32 investor = _getActor().toBytes32();
        AssetId payoutAssetId = _getAssetId();

        batchRequestManager.forceCancelRedeemRequest{value: MAX_MESSAGE_COST}(poolId, scId, investor, payoutAssetId, _getActor());
    }

    function hub_setMaxAssetPriceAge(uint32 maxAge) public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        hub.setMaxAssetPriceAge{value: MAX_MESSAGE_COST}(poolId, scId, assetId, uint64(maxAge), _getActor());
    }

    function hub_setMaxSharePriceAge(
        uint16 centrifugeId,
        uint32 maxAge
    ) public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.setMaxSharePriceAge{value: MAX_MESSAGE_COST}(poolId, scId, centrifugeId, uint64(maxAge), _getActor());
    }

    function hub_updateHoldingValue() public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        hub.updateHoldingValue(poolId, scId, assetId);
    }

    function hub_updateJournal(
        uint64 poolId,
        uint8 accountToUpdate,
        uint128 debitAmount,
        uint128 creditAmount
    ) public updateGhosts {
        AccountId accountId = createdAccountIds[
            accountToUpdate % createdAccountIds.length
        ];
        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: debitAmount, accountId: accountId});
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: creditAmount, accountId: accountId});

        hub.updateJournal(PoolId.wrap(poolId), debits, credits);
    }

    function hub_updateJournal_clamped(
        uint64 /* poolEntropy */,
        uint64 /* poolEntropy */,
        uint8 accountToUpdate,
        uint128 debitAmount,
        uint128 creditAmount
    ) public updateGhosts {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();

        AccountId accountId = createdAccountIds[
            accountToUpdate % createdAccountIds.length
        ];
        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: debitAmount, accountId: accountId});
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: creditAmount, accountId: accountId});

        hub.updateJournal(poolId, debits, credits);
    }

    // === RestrictedTransfers === ///
    function restrictedTransfers_updateMemberBasic(
        uint64 validUntil
    ) public asAdmin {
        fullRestrictions.updateMember(
            _getShareToken(),
            _getActor(),
            validUntil
        );
    }

    // TODO: We prob want to keep one generic
    // And one with limited actors
    function restrictedTransfers_updateMember(
        address user,
        uint64 validUntil
    ) public asAdmin {
        fullRestrictions.updateMember(_getShareToken(), user, validUntil);
    }

    function restrictedTransfers_freeze() public asAdmin {
        fullRestrictions.freeze(_getShareToken(), _getActor());
    }

    function restrictedTransfers_unfreeze() public asAdmin {
        fullRestrictions.unfreeze(_getShareToken(), _getActor());
    }

    /// === Hub === ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {D18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Test Utils
import {BeforeAfter, OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";

/// @dev Admin functions called by the admin actor
abstract contract AdminTargets is BaseTargetFunctions, Properties {
    using CastLib for *;

    event InterestingCoverageLog();

    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// === STATE FUNCTIONS === ///
    /// @dev These explicitly clamp the investor to always be one of the actors

    function hub_addShareClass(uint256 salt) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        hub.addShareClass(poolId, name, symbol, bytes32(salt));
    }

    function hub_approveDeposits(uint32 nowDepositEpochId, uint128 maxApproval) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId paymentAssetId = hubRegistry.currency(poolId);
        uint128 pendingDepositBefore = shareClassManager.pendingDeposit(scId, paymentAssetId);

        hub.approveDeposits(poolId, scId, paymentAssetId, nowDepositEpochId, maxApproval);

        uint128 pendingDepositAfter = shareClassManager.pendingDeposit(scId, paymentAssetId);
        uint128 approvedAssetAmount = pendingDepositBefore - pendingDepositAfter;
        approvedDeposits[scId][paymentAssetId] += approvedAssetAmount;
    }

    function hub_approveRedeems(uint32 nowRedeemEpochId, uint128 maxApproval) public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        uint128 pendingRedeemBefore = shareClassManager.pendingRedeem(scId, payoutAssetId);

        hub.approveRedeems(poolId, scId, payoutAssetId, nowRedeemEpochId, maxApproval);

        uint128 pendingRedeemAfter = shareClassManager.pendingRedeem(scId, payoutAssetId);
        uint128 approvedAssetAmount = pendingRedeemBefore - pendingRedeemAfter;
        approvedRedemptions[scId][payoutAssetId] += approvedAssetAmount;
    }

    function hub_approveRedeems_clamped(uint32 nowRedeemEpochId, uint128 maxApproval) public {
        hub_approveRedeems(nowRedeemEpochId, maxApproval);
    }

    function hub_createAccount(uint32 accountAsInt, bool isDebitNormal) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        AccountId account = AccountId.wrap(accountAsInt);
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
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = hubRegistry.currency(poolId);

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

    function hub_createHolding_clamped(
        bool isIdentityValuation,
        uint8 assetAccountEntropy,
        uint8 equityAccountEntropy,
        uint8 lossAccountEntropy,
        uint8 gainAccountEntropy
    ) public {
        IValuation valuation =
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));
        AccountId assetAccount = Helpers.getRandomAccountId(createdAccountIds, assetAccountEntropy);
        AccountId equityAccount = Helpers.getRandomAccountId(createdAccountIds, equityAccountEntropy);
        AccountId lossAccount = Helpers.getRandomAccountId(createdAccountIds, lossAccountEntropy);
        AccountId gainAccount = Helpers.getRandomAccountId(createdAccountIds, gainAccountEntropy);

        hub_initializeHolding(valuation, assetAccount.raw(), equityAccount.raw(), lossAccount.raw(), gainAccount.raw());
    }

    function hub_initializeLiability(IValuation valuation, uint32 expenseAccountAsUint, uint32 liabilityAccountAsUint)
        public
        updateGhosts
    {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(_getAssetId());
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
        IValuation valuation =
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));
        AccountId expenseAccount = Helpers.getRandomAccountId(createdAccountIds, expenseAccountEntropy);
        AccountId liabilityAccount = Helpers.getRandomAccountId(createdAccountIds, liabilityAccountEntropy);

        hub_initializeLiability(valuation, expenseAccount.raw(), liabilityAccount.raw());
    }

    /// @dev Property: After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance
    /// totalIssuance[..] is increased
    // TODO: Refactor this property to work with new issuance update logic
    function hub_issueShares(uint32 nowIssueEpochId, uint128 navPerShare) public updateGhostsWithType(OpType.ADD) {
        uint128 totalIssuanceBefore;
        uint128 totalIssuanceAfter;

        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(_getAssetId());
        uint256 escrowSharesBefore = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        (totalIssuanceBefore,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesBefore,,,) = balanceSheet.queuedShares(poolId, scId);

        (uint128 issuedShareAmount,,) = hub.issueShares(poolId, scId, assetId, nowIssueEpochId, D18.wrap(navPerShare), 0);

        uint256 escrowSharesAfter = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        (totalIssuanceAfter,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesAfter,,,) = balanceSheet.queuedShares(poolId, scId);

        uint256 escrowShareDelta = escrowSharesAfter - escrowSharesBefore;
        executedInvestments[_getShareToken()] += escrowShareDelta;
        issuedHubShares[poolId][scId][assetId] += issuedShareAmount;

        // TODO: Refactor this to work with new issuance update logic
        // if(navPerShare > 0) {
        //     gt(totalIssuanceAfter, totalIssuanceBefore, "total issuance is not increased after issueShares");
        // }
    }

    function hub_issueShares_clamped(uint32 nowIssueEpochId, uint128 navPerShare) public {
        hub_issueShares(nowIssueEpochId, navPerShare);
    }

    function hub_notifyPool(uint16 centrifugeId) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        hub.notifyPool(poolId, centrifugeId);
    }

    function hub_notifyPool_clamped() public {
        hub_notifyPool(CENTRIFUGE_CHAIN_ID);
    }

    function hub_notifyShareClass(uint16 centrifugeId, bytes32 hook) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.notifyShareClass(poolId, scId, centrifugeId, hook);
    }

    function hub_notifyShareClass_clamped(bytes32 hook) public {
        hub_notifyShareClass(CENTRIFUGE_CHAIN_ID, hook);
    }

    function hub_notifySharePrice(uint16 centrifugeId) public updateGhostsWithType(OpType.UPDATE) {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.notifySharePrice(poolId, scId, centrifugeId);
    }

    function hub_notifySharePrice_clamped() public {
        hub_notifySharePrice(CENTRIFUGE_CHAIN_ID);
    }

    function hub_notifyAssetPrice() public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = hubRegistry.currency(poolId);
        hub.notifyAssetPrice(poolId, scId, assetId);
    }

    /// @dev Property: After FM performs approveRedeems and revokeShares with non-zero navPerShare, the total issuance
    /// totalIssuance[..] is decreased
    // TODO: Refactor this property to work with new issuance update logic
    function hub_revokeShares(uint32 nowRevokeEpochId, uint128 navPerShare)
        public
        updateGhostsWithType(OpType.REMOVE)
    {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        uint256 sharesBefore = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        (uint128 totalIssuanceBefore,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesBefore,,,) = balanceSheet.queuedShares(poolId, scId);

        (uint128 revokedShareAmount,,) =
            hub.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, D18.wrap(navPerShare), 0);

        uint256 sharesAfter = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        uint256 burnedShares = sharesBefore - sharesAfter;
        (uint128 totalIssuanceAfter,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesAfter,,,) = balanceSheet.queuedShares(poolId, scId);

        // NOTE: shares are burned on revoke
        executedRedemptions[vault.share()] += burnedShares;
        revokedHubShares[poolId][scId][payoutAssetId] += revokedShareAmount;

        // if(navPerShare > 0) {
        //     lt(totalIssuanceAfter, totalIssuanceBefore, "total issuance is not decreased after revokeShares");
        // }
    }

    function hub_setAccountMetadata(uint32 accountAsInt, bytes memory metadata) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        AccountId account = AccountId.wrap(accountAsInt);
        hub.setAccountMetadata(poolId, account, metadata);
    }

    function hub_setHoldingAccountId(uint128 assetIdAsUint, uint8 kind, uint32 accountIdAsInt) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        AccountId accountId = AccountId.wrap(accountIdAsInt);
        hub.setHoldingAccountId(poolId, scId, assetId, kind, accountId);
    }

    function hub_setPoolMetadata(bytes memory metadata) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        hub.setPoolMetadata(poolId, metadata);
    }

    function hub_updateHoldingValuation(uint128 assetIdAsUint, IValuation valuation) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(assetIdAsUint);
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
    }

    function hub_updateHoldingValuation_clamped(bool isIdentityValuation) public {
        PoolId poolId = PoolId.wrap(_getPool());
        AssetId assetId = hubRegistry.currency(poolId);
        IValuation valuation =
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));
        hub_updateHoldingValuation(assetId.raw(), valuation);
    }

    function hub_updateRestriction(uint16 chainId, bytes calldata payload) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.updateRestriction(poolId, scId, chainId, payload, 0);
    }

    function hub_updateRestriction_clamped(bytes calldata payload) public {
        hub_updateRestriction(CENTRIFUGE_CHAIN_ID, payload);
    }

    function syncManager_setValuation(address valuation) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        syncManager.setValuation(poolId, scId, valuation);
    }

    function syncManager_setValuation_clamped(bool isIdentityValuation) public {
        address valuation = isIdentityValuation ? address(identityValuation) : address(transientValuation);
        syncManager_setValuation(valuation);
    }

    function hub_updateSharePrice(uint64 poolIdAsUint, bytes16 scIdAsBytes, uint128 navPoolPerShare)
        public
        updateGhosts
    {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.updateSharePrice(poolId, scId, D18.wrap(navPoolPerShare));
    }

    function hub_forceCancelDepositRequest() public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes32 investor = _getActor().toBytes32();
        AssetId depositAssetId = hubRegistry.currency(poolId);

        hub.forceCancelDepositRequest(poolId, scId, investor, depositAssetId);
    }

    function hub_forceCancelRedeemRequest() public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes32 investor = _getActor().toBytes32();
        AssetId payoutAssetId = hubRegistry.currency(poolId);

        hub.forceCancelRedeemRequest(poolId, scId, investor, payoutAssetId);
    }

    function hub_setMaxAssetPriceAge(uint32 maxAge) public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        hub.setMaxAssetPriceAge(poolId, scId, assetId, maxAge);
    }

    function hub_setMaxSharePriceAge(uint16 centrifugeId, uint32 maxAge) public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        hub.setMaxSharePriceAge(centrifugeId, poolId, scId, maxAge);
    }

    function hub_updateHoldingValue() public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = hubRegistry.currency(poolId);

        hub.updateHoldingValue(poolId, scId, assetId);
    }

    function hub_updateJournal(uint64 poolId, uint8 accountToUpdate, uint128 debitAmount, uint128 creditAmount)
        public
        updateGhosts
    {
        AccountId accountId = createdAccountIds[accountToUpdate % createdAccountIds.length];
        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: debitAmount, accountId: accountId});
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: creditAmount, accountId: accountId});

        hub.updateJournal(PoolId.wrap(poolId), debits, credits);
    }

    function hub_updateJournal_clamped(
        uint64 poolEntropy,
        uint8 accountToUpdate,
        uint128 debitAmount,
        uint128 creditAmount
    ) public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();

        AccountId accountId = createdAccountIds[accountToUpdate % createdAccountIds.length];
        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: debitAmount, accountId: accountId});
        JournalEntry[] memory credits = new JournalEntry[](1);
        credits[0] = JournalEntry({value: creditAmount, accountId: accountId});

        hub.updateJournal(poolId, debits, credits);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}

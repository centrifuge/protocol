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
abstract contract AdminTargets is
    BaseTargetFunctions,
    Properties
{
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

    function hub_createHolding(IValuation valuation, uint32 assetAccountAsUint, uint32 equityAccountAsUint, uint32 lossAccountAsUint, uint32 gainAccountAsUint) public updateGhosts {
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

    function hub_createHolding_clamped(bool isIdentityValuation, uint8 assetAccountEntropy, uint8 equityAccountEntropy, uint8 lossAccountEntropy, uint8 gainAccountEntropy) public {
        IValuation valuation = isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));
        AccountId assetAccount = Helpers.getRandomAccountId(createdAccountIds, assetAccountEntropy);
        AccountId equityAccount = Helpers.getRandomAccountId(createdAccountIds, equityAccountEntropy);
        AccountId lossAccount = Helpers.getRandomAccountId(createdAccountIds, lossAccountEntropy);
        AccountId gainAccount = Helpers.getRandomAccountId(createdAccountIds, gainAccountEntropy);

        hub_createHolding(valuation, assetAccount.raw(), equityAccount.raw(), lossAccount.raw(), gainAccount.raw());
    }

    function hub_initializeLiability(IValuation valuation, uint32 expenseAccountAsUint, uint32 liabilityAccountAsUint) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(_getAssetId());
        hub.initializeLiability(poolId, scId, assetId, valuation, AccountId.wrap(expenseAccountAsUint), AccountId.wrap(liabilityAccountAsUint));
    }
    
    function hub_initializeLiability_clamped(bool isIdentityValuation, uint8 expenseAccountEntropy, uint8 liabilityAccountEntropy) public {
        IValuation valuation = isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));
        AccountId expenseAccount = Helpers.getRandomAccountId(createdAccountIds, expenseAccountEntropy);
        AccountId liabilityAccount = Helpers.getRandomAccountId(createdAccountIds, liabilityAccountEntropy);
        
        hub_initializeLiability(valuation, expenseAccount.raw(), liabilityAccount.raw());
    }
    
    /// @dev Property: After FM performs approveDeposits and issueShares with non-zero navPerShare, the total issuance totalIssuance[..] is increased
    function hub_issueShares(uint32 nowIssueEpochId, uint128 navPerShare) public updateGhosts {
        uint128 totalIssuanceBefore;
        uint128 totalIssuanceAfter;

        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        AssetId assetId = AssetId.wrap(_getAssetId());
        uint256 escrowSharesBefore = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        (totalIssuanceBefore,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesBefore,,,) = balanceSheet.queuedShares(poolId, scId);
        
        (uint128 issuedShareAmount,,) = hub.issueShares(poolId, scId, assetId, nowIssueEpochId, D18.wrap(navPerShare));

        uint256 escrowSharesAfter = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        (totalIssuanceAfter,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesAfter,,,) = balanceSheet.queuedShares(poolId, scId);

        uint256 escrowShareDelta = escrowSharesAfter - escrowSharesBefore;
        executedInvestments[_getShareToken()] += escrowShareDelta;
        issuedHubShares[poolId][scId][assetId] += issuedShareAmount;

        if(navPerShare > 0) {
            gt(totalIssuanceAfter, totalIssuanceBefore, "total issuance is not increased after issueShares");
        }
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

    function hub_notifySharePrice(uint16 centrifugeId) public updateGhosts {
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
    
    function hub_setQueue(uint16 centrifugeId, bool enabled) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.setQueue(poolId, scId, enabled);
    }

    function hub_setQueue_clamped(bool enabled) public {
        hub_setQueue(CENTRIFUGE_CHAIN_ID, enabled);
    }

    /// @dev Property: After FM performs approveRedeems and revokeShares with non-zero navPerShare, the total issuance totalIssuance[..] is decreased
    function hub_revokeShares(uint32 nowRevokeEpochId, uint128 navPerShare) public updateGhosts {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId payoutAssetId = hubRegistry.currency(poolId);
        uint256 sharesBefore = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        (uint128 totalIssuanceBefore,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesBefore,,,) = balanceSheet.queuedShares(poolId, scId);
        
        (uint128 revokedShareAmount,,) = hub.revokeShares(poolId, scId, payoutAssetId, nowRevokeEpochId, D18.wrap(navPerShare));

        uint256 sharesAfter = IShareToken(_getShareToken()).balanceOf(address(globalEscrow));
        uint256 burnedShares = sharesBefore - sharesAfter;
        (uint128 totalIssuanceAfter,) = shareClassManager.metrics(scId);
        (uint128 balanceSheetSharesAfter,,,) = balanceSheet.queuedShares(poolId, scId);

        // NOTE: shares are burned on revoke 
        executedRedemptions[vault.share()] += burnedShares;
        revokedHubShares[poolId][scId][payoutAssetId] += revokedShareAmount;

        if(navPerShare > 0) {
            lt(totalIssuanceAfter, totalIssuanceBefore, "total issuance is not decreased after revokeShares");
        }
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
        IValuation valuation = isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));
        hub_updateHoldingValuation(assetId.raw(), valuation);
    }

    function hub_updateRestriction(uint16 chainId, bytes calldata payload) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        hub.updateRestriction(poolId, scId, chainId, payload);
    }

    function hub_updateRestriction_clamped(bytes calldata payload) public {
        hub_updateRestriction(CENTRIFUGE_CHAIN_ID, payload);
    }

    function syncRequestManager_setValuation(address valuation) public updateGhosts {
        PoolId poolId = PoolId.wrap(_getPool());
        ShareClassId scId = ShareClassId.wrap(_getShareClassId());
        syncRequestManager.setValuation(poolId, scId, valuation);
    }

    function syncRequestManager_setValuation_clamped(bool isIdentityValuation) public {
        address valuation = isIdentityValuation ? address(identityValuation) : address(transientValuation);
        syncRequestManager_setValuation(valuation);
    }
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}